#!/bin/bash
# 本地验证 set-agent-proxy.py —— 在本机用仿造的 config.toml 跑通各条路径,不碰容器。
#
# 为什么值得单独验:
#   这段代码改的是 cc-connect 的配置文件,改坏了下场是"机器人起不来",比不挂代理
#   严重得多。而最容易踩的坑不是语法 —— 是 TOML 的**键归属**:env 子表插错位置,
#   配置照样能解析,但 work_dir / mode 会悄悄变成 env 的子键,表现是 agent 找不到
#   工作目录。所以这里断言的重点是"改写之后 options 的键还归 options",
#   光断言"能解析"是不够的。
#
# 夹具(fixture)照抄 deploy-codex.sh 生成出来的形状,包括缩进与空行。
#   api_key 的取值故意写成一个字符 —— 全是占位符、没有断言看它的值,写长了会被
#   全局 pre-commit 的密钥正则(api[_-]?key\s*=\s*"…6 字以上)拦下。与其用
#   GIT_NO_SECRET_CHECK=1 绕过那道闸门,不如让夹具本身不带可疑字面量。
# 所有产物都在 .verify-agent-proxy/ 内,不写项目外任何位置。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/set-agent-proxy.py"
VD="$HERE/.verify-agent-proxy"
CFG="$VD/config.toml"

# 挑一个**真能跑**的 python:Windows 上 `command -v python3` 常指到
# WindowsApps 下的应用商店占位程序,它什么都不输出、也不报错 —— 直接用它会让
# 整个验证跑成"所有断言都失败但看不出原因"。所以按"能不能 import tomllib"来挑,
# 顺带保证回验用的解析器可用(需要 3.11+)。
pick_python() {
    local c
    for c in python python3 py; do
        if command -v "$c" >/dev/null 2>&1 \
           && "$c" -c 'import tomllib' >/dev/null 2>&1; then
            command -v "$c"; return 0
        fi
    done
    return 1
}
PY="$(pick_python)"
if [ -z "$PY" ]; then
    echo "❌ 找不到可用的 python(需 3.11+,要能 import tomllib)"
    exit 1
fi
[ -f "$SRC" ] || { echo "❌ 找不到 $SRC"; exit 1; }

rm -rf "$VD"; mkdir -p "$VD"

PASS=0
FAILED=0
pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ❌ $1"; }
# $2 有 -- 前缀时 grep 会当成选项,必须用 `--` 断开
chk()  { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 —— 实际输出:"; printf '%s\n' "$3" | sed 's/^/     | /'; fi; }
nchk() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 —— 实际输出:"; printf '%s\n' "$3" | sed 's/^/     | /'; else pass "$1"; fi; }

# -----------------------------------------------------------------------------
# 夹具:两段 project(codex / claudecode),形状与 deploy-codex.sh 生成的一致
# -----------------------------------------------------------------------------
make_fixture() {
    local path="$1" extra="${2:-}"
    # 上一场景留下的备份会让"无改动不写备份"这类断言假阳性,先清掉
    rm -f "$path.bak"
    cat > "$path" <<'EOF'
data_dir = "/workspace/cc-connect/data"

# Codex:密钥由 cc-connect 注入为 OPENAI_API_KEY 并写入 auth.json,
# 容器全局环境变量无需配置;codex_home 落 /workspace 保证重启 VM 后会话仍在。
[[projects]]
name = "codex"

  [projects.agent]
    type = "codex"

    [projects.agent.options]
      work_dir = "/workspace"
      codex_home = "/workspace/codex-home"
      provider = "cx-provider"
      mode = "auto-edit"
      sandbox_mode = "workspace-write"
      approval_policy = "on-request"

    [[projects.agent.providers]]
      name = "cx-provider"
      api_key = "x"
      base_url = "https://example.invalid/v1"
      model = "gpt-5"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_fakecodex"
      app_secret = "fake"

[[projects]]
name = "claude"

  [projects.agent]
    type = "claudecode"

    [projects.agent.options]
      work_dir = "/workspace"
      mode = "default"
      provider = "cl-provider"

    [[projects.agent.providers]]
      name = "cl-provider"
      api_key = "y"
      base_url = "https://example.invalid"
      model = "claude-sonnet-5"

      [projects.agent.providers.env]
        ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-sonnet-5"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_fakeclaude"
      app_secret = "fake"
EOF
    [ -n "$extra" ] && cat "$extra" >> "$path"
    return 0
}

# 第三段:非目标 agent 类型(ACP),用来验证"不该动的没被动"
cat > "$VD/other-block.toml" <<'EOF'

[[projects]]
name = "other"

  [projects.agent]
    type = "acp"

    [projects.agent.options]
      work_dir = "/workspace"
EOF

run() { "$PY" "$SRC" --config "$CFG" "$@" 2>&1; }

# 用 python 读回某个 project 的 agent.options,证明键归属正确
probe() {  # $1=project名 $2=表达式(在 options 字典上求值)
    "$PY" - "$CFG" "$1" "$2" <<'PYEOF' 2>&1
import sys, tomllib
cfg, proj, expr = sys.argv[1], sys.argv[2], sys.argv[3]
doc = tomllib.load(open(cfg, "rb"))
p = next((x for x in doc.get("projects", []) if x.get("name") == proj), None)
if p is None:
    print("NO_PROJECT"); raise SystemExit
opts = (p.get("agent") or {}).get("options") or {}
print(eval(expr, {"o": opts, "env": opts.get("env") or {}}))
PYEOF
}

echo "═══ 语法与静态检查 ═══"
# PYTHONPYCACHEPREFIX:让 py_compile 的 .pyc 落进 .verify-agent-proxy/,
# 否则它会往仓库根目录写一个 __pycache__(被验证的脚本不该在被验证时就弄脏仓库)。
if PYTHONPYCACHEPREFIX="$VD/pyc" "$PY" -m py_compile "$SRC" 2>"$VD/pyc.err"; then pass "py_compile 通过"; else fail "py_compile 失败: $(cat "$VD/pyc.err")"; fi
chk "帮助里写明了 --on / --off" "--off" "$(run --help)"

echo
echo "═══ 场景 A：--on 挂上 ═══"
make_fixture "$CFG"
cp "$CFG" "$VD/before.toml"
OUT=$(run --on)
chk "A codex 已挂上"   "codex: 已挂上" "$OUT"
chk "A claude 已挂上"  "claude: 已挂上" "$OUT"
chk "A 写了备份"       "备份:" "$OUT"
[ -f "$CFG.bak" ] && pass "A 备份文件存在" || fail "A 备份文件不存在"
if cmp -s "$VD/before.toml" "$CFG.bak"; then pass "A 备份内容 = 改前内容"; else fail "A 备份内容与改前不一致"; fi

# 键归属 —— 本次验证的核心
[ "$(probe codex "o.get('work_dir')")" = "/workspace" ] && pass "A codex work_dir 未被 env 抢走" || fail "A codex work_dir 丢了(变成 $(probe codex "o.get('work_dir')"))"
[ "$(probe codex "o.get('mode')")" = "auto-edit" ] && pass "A codex mode 未被 env 抢走" || fail "A codex mode 丢了"
[ "$(probe claude "o.get('provider')")" = "cl-provider" ] && pass "A claude provider 未被 env 抢走" || fail "A claude provider 丢了"
[ "$(probe codex "o.get('provider')")" = "cx-provider" ] && pass "A codex provider 未被 env 抢走" || fail "A codex provider 丢了"

# env 值本身
chk "A codex 的 HTTPS_PROXY"    "http://127.0.0.1:7890" "$(probe codex "env.get('HTTPS_PROXY')")"
chk "A claude 的 HTTPS_PROXY"   "http://127.0.0.1:7890" "$(probe claude "env.get('HTTPS_PROXY')")"
chk "A codex 的 ALL_PROXY"      "socks5://127.0.0.1:7891" "$(probe codex "env.get('ALL_PROXY')")"
chk "A NO_PROXY 含 127.0.0.1(否则 codex 的 ws://127.0.0.1:3845 会走代理)" "127.0.0.1" "$(probe codex "env.get('NO_PROXY')")"
chk "A 四个键齐全" "4" "$(probe codex "len(env)")"

# 位置:env 子表必须紧跟在 options 的直接键之后、下一个表头之前
N_ENV=$(grep -c "^ *\[projects.agent.options.env\]" "$CFG")
[ "$N_ENV" = "2" ] && pass "A env 子表恰好 2 处(两个 project 各一)" || fail "A env 子表有 $N_ENV 处,期望 2"
LINE_APPROVAL=$(grep -n "approval_policy" "$CFG" | head -1 | cut -d: -f1)
LINE_ENV=$(grep -n "^ *\[projects.agent.options.env\]" "$CFG" | head -1 | cut -d: -f1)
LINE_PROVIDERS=$(grep -n "\[\[projects.agent.providers\]\]" "$CFG" | head -1 | cut -d: -f1)
if [ -n "$LINE_ENV" ] && [ -n "$LINE_APPROVAL" ] && [ -n "$LINE_PROVIDERS" ] \
   && [ "$LINE_ENV" -gt "$LINE_APPROVAL" ] && [ "$LINE_ENV" -lt "$LINE_PROVIDERS" ]; then
    pass "A env 子表落在 options 键之后、providers 表头之前($LINE_APPROVAL < $LINE_ENV < $LINE_PROVIDERS)"
else
    fail "A env 子表位置不对:approval=$LINE_APPROVAL env=$LINE_ENV providers=$LINE_PROVIDERS"
fi

echo
echo "═══ 场景 B：幂等(再挂一次不该变)═══"
cp "$CFG" "$VD/after-on.toml"
OUT=$(run --on)
cmp -s "$VD/after-on.toml" "$CFG" && pass "B 再跑一次 --on 文件字节不变" || fail "B 文件被改动(不幂等)"
N_ENV=$(grep -c "^ *\[projects.agent.options.env\]" "$CFG")
[ "$N_ENV" = "2" ] && pass "B env 子表仍是 2 处(没插重复)" || fail "B env 子表变成 $N_ENV 处"

echo
echo "═══ 场景 C：--off 摘掉 ═══"
OUT=$(run --off)
chk "C codex 已摘掉"  "codex: 已摘掉" "$OUT"
chk "C claude 已摘掉" "claude: 已摘掉" "$OUT"
N_ENV=$(grep -c "options.env" "$CFG")
[ "$N_ENV" = "0" ] && pass "C env 子表已删净" || fail "C 还剩 $N_ENV 处 options.env"
[ "$(probe codex "o.get('work_dir')")" = "/workspace" ] && pass "C 删除后 work_dir 仍归 options" || fail "C 删除后 work_dir 丢了"
[ "$(probe codex "o.get('approval_policy')")" = "on-request" ] && pass "C 删除后 approval_policy 仍在" || fail "C 删除后 approval_policy 丢了"
[ "$(probe codex "len(env)")" = "0" ] && pass "C env 已空" || fail "C env 未清空"
# 删除后应与改前完全一致 —— 说明增删是对称的,不留残迹
cmp -s "$VD/before.toml" "$CFG" && pass "C 删完与改前逐字节一致(增删对称)" || { fail "C 删完与改前不一致"; diff "$VD/before.toml" "$CFG" | head -10 | sed 's/^/     | /'; }

echo
echo "═══ 场景 D：--off 空跑 ═══"
cp "$CFG" "$VD/after-off.toml"
OUT=$(run --off)
chk "D 报本就未挂" "本就没挂" "$OUT"
cmp -s "$VD/after-off.toml" "$CFG" && pass "D 没动文件" || fail "D 文件被改动"

echo
echo "═══ 场景 E：不带 --on/--off = 只读巡检 ═══"
make_fixture "$CFG"
cp "$CFG" "$VD/before-scan.toml"
OUT=$(run)
chk "E 列出 codex"  "codex" "$OUT"
chk "E 列出 claude" "claude" "$OUT"
chk "E 标明未挂"    "➖ 未挂" "$OUT"
cmp -s "$VD/before-scan.toml" "$CFG" && pass "E 巡检不改文件" || fail "E 巡检改了文件"
run --on >/dev/null
OUT=$(run)
chk "E 挂上后标明已挂" "✅ 已挂" "$OUT"

echo
echo "═══ 场景 F：非目标 agent 类型不得被动 ═══"
make_fixture "$CFG" "$VD/other-block.toml"
OUT=$(run --on)
chk "F 报出 other 不在范围" "other: type=acp,不在本次范围" "$OUT"
chk "F 仍挂上了 codex"      "codex: 已挂上" "$OUT"
[ "$(probe other "len(env)")" = "0" ] && pass "F other 没被塞 env" || fail "F other 被塞了 env"
[ "$(probe other "o.get('work_dir')")" = "/workspace" ] && pass "F other 的 options 完好" || fail "F other 的 options 被破坏"

echo
echo "═══ 场景 G：没有 [projects.agent.options] 的 project 应跳过而非写坏 ═══"
rm -f "$CFG.bak"
cat > "$CFG" <<'EOF'
[[projects]]
name = "naked"

  [projects.agent]
    type = "codex"
EOF
cp "$CFG" "$VD/before-naked.toml"
OUT=$(run --on)
chk "G 报出缺 options 段" "没有 [projects.agent.options],跳过" "$OUT"
cmp -s "$VD/before-naked.toml" "$CFG" && pass "G 配置未被改动" || fail "G 配置被改坏了"
[ -f "$CFG.bak" ] && fail "G 无改动却写了备份" || pass "G 无改动不写备份"

echo
echo "═══ 场景 H：自定义代理地址 ═══"
make_fixture "$CFG"
OUT=$(run --on --proxy http://10.0.0.9:1080 --no-proxy "localhost,127.0.0.1")
chk "H HTTPS_PROXY 用了自定义值" "http://10.0.0.9:1080" "$(probe codex "env.get('HTTPS_PROXY')")"
chk "H NO_PROXY 用了自定义值"    "localhost,127.0.0.1" "$(probe codex "env.get('NO_PROXY')")"

echo
echo "═══ 场景 I：配置文件本身不合法时必须停手 ═══"
rm -f "$CFG.bak"
printf '[[projects]\nname = "broken"\n' > "$CFG"
cp "$CFG" "$VD/before-broken.toml"
OUT=$(run --on)
chk "I 报出不是合法 TOML" "不是合法 TOML" "$OUT"
cmp -s "$VD/before-broken.toml" "$CFG" && pass "I 坏配置原样没动" || fail "I 坏配置被覆写"
[ -f "$CFG.bak" ] && fail "I 无改动却写了备份" || pass "I 无改动不写备份"

echo
echo "═══ 场景 J：--on 与 --off 同时给应拒绝 ═══"
OUT=$(run --on --off)
chk "J 拒绝并说明" "只能给一个" "$OUT"

echo
echo "═══════════════════════════════════════════"
echo "  通过 $PASS 项，失败 $FAILED 项"
echo "═══════════════════════════════════════════"
[ "$FAILED" = 0 ] || exit 1
