#!/bin/bash
# 本地验证 inspect-state.sh:用仿造夹具跑一遍,断言输出里的关键结论
#
# 为什么值得单独验:这个脚本是**唯一**在共享终端窗口期里跑的东西,而窗口期只有
# 十分钟左右 —— 它要是打错或崩在中途,就得让用户重新生成一次密码。所以本机先把
# 每条分支跑通:对表(一致/不一致)、只在心跳不在任务、出网探测、以及"认错台"的守卫。
#
# 网络与 cloudflared 都打桩:夹具里放一个假 curl,免得本机验证受网络影响。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

SB=".verify-inspect"
rm -rf "$SB"
mkdir -p "$SB/ws/cc-connect/data/crons" "$SB/bin"
WS="$SB/ws/cc-connect"

# ── 夹具:3 个 project(codex / codex1 带心跳,claude 不带),2 条任务
#     codex  → 会话键与心跳一致
#     claude → 该 project 没有心跳段(考察"任务在、心跳不在"的显示)
cat > "$WS/config.toml" <<'TOML'
[projects]
name = "codex"

[projects.codex]
name = "codex"

[projects.codex.heartbeat]
enabled = true
interval_mins = 30
session_key = "feishu:oc_AAA111:ou_111aaa"
timeout_mins = 30
silent = false
prompt = "请继续之前的工作"

[projects.codex1]
name = "codex1"

[projects.codex1.heartbeat]
enabled = true
interval_mins = 30
session_key = "feishu:oc_BBB222:ou_222bbb"
timeout_mins = 30

[projects.claude]
name = "claude"
TOML

cat > "$WS/data/crons/jobs.json" <<'JSON'
[
  {"id":"a1","project":"codex","session_key":"feishu:oc_AAA111:ou_111aaa","cron_expr":"1 * * * *",
   "prompt":"","exec":"/usr/bin/python3 /workspace/cc-connect/rotate-codex-session.py","description":"每小时清空 codex 会话上下文",
   "enabled":true,"silent":true,"mute":true,"timeout_mins":30},
  {"id":"b2","project":"claude","session_key":"feishu:oc_CCC333:ou_333ccc","cron_expr":"2 * * * *",
   "prompt":"说一句早安","exec":"","description":"早安","enabled":true,"silent":false,"mute":false,"timeout_mins":30}
]
JSON

cat > "$WS/cc.log" <<'LOG'
2026-09-24 engine started project=codex
2026-09-24 engine started project=codex1
2026-09-24 websocket error project=codex2
LOG

# 假 curl:探测一律返回 599,固定格式,验证的是脚本的排版与分支
printf '#!/bin/sh\necho -n "HTTP 599"\n' > "$SB/bin/curl"
chmod +x "$SB/bin/curl"
# 本机没有 python3(Windows 上是应用商店占位符,静默退出),容器里是真的 3.11.2 ——
# 用桩把它指到本机真 python,否则第 1 节的 tomllib 对表根本不会跑
printf '#!/bin/sh\nexec python "$@"\n' > "$SB/bin/python3"
printf '#!/bin/sh\necho 0\nexit 1\n' > "$SB/bin/pgrep"
chmod +x "$SB/bin/python3" "$SB/bin/pgrep"

# 把脚本里的绝对路径换成本机夹具(容器里就是 /workspace/cc-connect)
sed -e "s#/workspace/cc-connect#$HERE/$WS#g" inspect-state.sh > "$SB/run.sh"

fail=0
ck() { # ck <描述> <是否在场:0/1> <文本>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi
}
has() { grep -qF -- "$2" "$1"; }

echo "══ 夹具运行 inspect-state.sh ══"
out="$(PATH="$HERE/$SB/bin:$PATH" bash "$SB/run.sh" 2>&1)"
echo "$out" | sed 's/^/  | /'

echo
echo "══ 断言 ══"
printf '%s' "$out" > "$SB/out.txt"
grep -qF 'project 总数=3' "$SB/out.txt"; ck "project 总数=3" $?
grep -qF '带 [projects.heartbeat] 的=2' "$SB/out.txt"; ck "带心跳的=2" $?
grep -qF 'codex    enabled=True interval=30' "$SB/out.txt"; ck "心跳参数逐条列出" $?
grep -qF 'key尾=111aaa' "$SB/out.txt"; ck "会话键只打尾 6 位" $?
grep -qF '任务数=2' "$SB/out.txt"; ck "任务数=2" $?
grep -qF '会话键=一致' "$SB/out.txt"; ck "codex 的键对表一致" $?
grep -qF '会话键=❌不一致' "$SB/out.txt"; ck "claude(无心跳段)的键判为不一致" $?
grep -qF "有心跳但没有任务:['codex1']" "$SB/out.txt"; ck "提示 codex1 有心跳没任务" $?
grep -qF 'HTTP 599' "$SB/out.txt"; ck "出网探测段打桩生效" $?
grep -qF 'DNS probe.trycloudflare.com' "$SB/out.txt"; ck "DNS 段有输出" $?
grep -qF '近 400 行:engine started=2' "$SB/out.txt"; ck "日志计数正确" $?
grep -qF '══ 结束 ══' "$SB/out.txt"; ck "脚本跑到结尾(没中途崩)" $?
if printf '%s' "$out" | grep -qE 'ou_111aaa|oc_AAA111'; then
  echo "  ❌ 输出里出现了完整会话键(应当只留尾 6 位)"; fail=1
else
  echo "  ✅ 输出里没有完整会话键"
fi

echo
echo "══ 认错台的守卫 ══"
guard="$(bash inspect-state.sh 2>&1)"; rc=$?
echo "$guard" | sed 's/^/  | /'
printf '%s' "$guard" | grep -qF '不像 MonkeyCode 那台'; ck "找不到 /workspace/cc-connect 时明确报错" $?
[ "$rc" -ne 0 ]; ck "守卫分支退出码非 0(rc=$rc)" $?

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ 全部断言通过"
  rm -rf "$SB"
else
  echo "❌ 有断言失败,夹具留在 $SB 供查看"
  exit 1
fi
