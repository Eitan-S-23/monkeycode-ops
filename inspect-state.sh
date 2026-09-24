#!/usr/bin/env bash
# 容器巡检:一条命令把"现在什么状态 + 哪条路能当常驻通道"看全
#
#   curl -fsSL https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/inspect-state.sh | bash
#
# 为什么有它(实测出来的三条约束,别忘):
#   · MonkeyCode 共享终端的密码大约十分钟就作废(实测:4~6 次连接后一律报"验证密码失败");
#   · 已经建立的 guest 连接**不会**被密码失效赶走 —— 密码只是入场券;
#   · 但**长命令经那个终端粘贴会被吃字、串引号**(实测:700 字符的命令把 shell 卡进了
#     dquote> 续行,只能靠 Ctrl-C 救),所以窗口期里只粘这一条极短的 curl|bash,
#     要看的东西让脚本自己打。
#
# 只读:不改文件、不装东西、不起进程。输出不含凭证:
#   · 会话键只打尾 6 位(够和任务对表,不够反推);
#   · git 远程地址与配置去敏(//user:token@host → //***@host)。
#
# 用法: bash inspect-state.sh [可选:一个要额外探测的地址(如某个 /health)]
set -u
# 容器里的 locale 多半是 POSIX,而 jobs.json / 输出里都有中文:
#   · 不显式指定编码,json.load(open(...)) 会按 ASCII 解,直接 UnicodeDecodeError;
#   · PYTHONIOENCODING 让下面所有 python 块的输出走 UTF-8,不随 locale 变。
export PYTHONIOENCODING=utf-8

R="${1:-}"

echo "══ 0. 身份 ══"
echo "  host=$(hostname)  python=$(python3 -V 2>&1)  utc=$(date -u '+%F %T')  uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)s"
if [ ! -d /workspace/cc-connect ]; then
  echo "  ❌ 没有 /workspace/cc-connect —— 这不像 MonkeyCode 那台,停在这里(别在腾讯那台上跑)"
  exit 1
fi
cd /workspace/cc-connect || exit 1

echo
echo "══ 1. 心跳与 /cron 任务对表(用 tomllib 读,不靠 grep)══"
python3 - <<'PY'
import json, os, tomllib
try:
    cfg = tomllib.load(open('config.toml', 'rb'))
except Exception as e:
    print('  ❌ config.toml 解析不过:', e); raise SystemExit(0)
projs_all = cfg.get('projects', {}) or {}
# [projects] 里可能混着 name 这类标量键(它们不是 project),只留表
projs = {k: v for k, v in projs_all.items() if isinstance(v, dict)}
hb = {k: v.get('heartbeat') for k, v in projs.items()
      if isinstance(v.get('heartbeat'), dict)}
print(f"  project 总数={len(projs)}  带 [projects.heartbeat] 的={len(hb)}")
stray = sorted(set(projs_all) - set(projs))
if stray:
    print(f"  (另有非表的键,不算 project:{stray})")
for k in sorted(hb, key=lambda s: (len(s), s)):
    v = hb[k]
    print(f"    {k:8s} enabled={v.get('enabled')} interval={v.get('interval_mins')} "
          f"silent={v.get('silent')} key尾={str(v.get('session_key'))[-6:]}")
p = 'data/crons/jobs.json'
if not os.path.exists(p):
    print("  jobs.json 不存在(这台没建过 /cron 任务)")
else:
    jobs = json.load(open(p, encoding='utf-8'))
    jm = {}
    for j in jobs:
        jm.setdefault(j.get('project'), []).append(j)
    print(f"  任务数={len(jobs)}  涉及 project={sorted(jm, key=lambda s: (len(s), s))}")
    for k in sorted(jm, key=lambda s: (len(s), s)):
        for j in jm[k]:
            same = '一致' if (hb.get(k) or {}).get('session_key') == j.get('session_key') else '❌不一致'
            body = (j.get('exec') or j.get('prompt') or '')[:56]
            print(f"    {k:8s} cron={j.get('cron_expr')} 会话键={same} {body}")
    only_hb = sorted(set(hb) - set(jm), key=lambda s: (len(s), s))
    if only_hb:
        print(f"  ⚠️ 有心跳但没有任务:{only_hb}")
PY

echo
echo "══ 2. 进程与日志 ══"
echo "  cc-connect 进程数=$(pgrep -fc 'cc-connect --config' || true)  watchdog=$(pgrep -fc 'watchdog.lock' || true)"
echo "  近 400 行:engine started=$(tail -400 cc.log 2>/dev/null | grep -c 'engine started' || true)  websocket error=$(tail -400 cc.log 2>/dev/null | grep -c 'websocket error' || true)"
tail -400 cc.log 2>/dev/null | grep -E 'engine' | tail -4 | sed 's/^/  /'
echo "  config.toml=$(stat -c '%s 字节 %y' config.toml 2>/dev/null | cut -c1-30)  .bak=$(stat -c '%s' config.toml.bak 2>/dev/null)"

echo
echo "══ 3. 出网:哪条路能当常驻通道 ══"
probe() { printf '  %-24s %s\n' "$2" "$(curl -sS -m 8 -o /dev/null -w 'HTTP %{http_code}' "$1" 2>/dev/null || echo 不通)"; }
probe https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/README.md raw.githubusercontent
probe https://api.github.com/ api.github.com
probe https://probe.trycloudflare.com/ trycloudflare.com
probe https://probe.workers.dev/ workers.dev
if [ -n "$R" ]; then probe "$R" "参数给的地址"; fi
python3 - <<'PY'
import socket
for h in ('api.github.com', 'probe.trycloudflare.com', 'probe.workers.dev'):
    try:
        print(f"  DNS {h:24s} {socket.gethostbyname(h)}")
    except Exception:
        print(f"  DNS {h:24s} 解析失败")
PY

echo
echo "══ 4. 现成的隧道与凭证(决定要不要新令牌)══"
echo "  cloudflared=$(command -v cloudflared || echo 无)  进程数=$(pgrep -fc cloudflared || true)"
ls -1 /workspace/cloudflared-state 2>/dev/null | head -6 | sed 's/^/  state: /'
timeout 12 cloudflared tunnel list 2>&1 | head -4 | sed 's/^/  tunnel: /'
git -C /workspace remote -v 2>/dev/null | sed -E 's#//[^@/]*@#//***@#g' | head -2 | sed 's/^/  remote: /'
echo "  git 身份=$(git config --global --get user.email || echo 无)  helper=$(git config --global --get credential.helper || echo 无)"
ls -1 /root/.git-credentials /root/.config/gh 2>/dev/null | head -3 | sed 's/^/  凭证文件: /'

echo
echo "══ 结束 ══"
