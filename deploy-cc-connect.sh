#!/bin/bash
# cc-connect 容器部署:用官方 cc-connect 桥接替换自研 feishu-bot
#
# 设计要点:
# 1) 同一飞书 App 同一时刻只能有一条长连接 —— 必须先停自研 bot,否则两边抢事件
# 2) 飞书凭证从现有 bot 配置读取,不经过聊天明文
# 3) 启动失败自动回滚到自研 bot,避免失去飞书通道
# 4) 容器无 systemd(cc-connect daemon 子命令依赖 systemd),复用 flock + 循环 watchdog
#
# 用法:bash /workspace/cc-connect/deploy.sh
# 回滚:bash /workspace/cc-connect/rollback.sh

set -uo pipefail

CC_DIR=/workspace/cc-connect
BOT_DIR=/workspace/feishu-bot
CONFIG="$CC_DIR/config.toml"
LOG="$CC_DIR/cc.log"

cd "$CC_DIR" 2>/dev/null || { echo "❌ 目录不存在: $CC_DIR"; exit 1; }

# ---------- 1. opencode 就位 ----------
echo "[1/5] 定位平台自带 opencode..."
OPENCODE_BIN=$(ls -d /root/.codingmatrix/bin/opencode-*/opencode 2>/dev/null | head -1)
if [ -n "$OPENCODE_BIN" ]; then
    echo "  ✅ 找到 $OPENCODE_BIN"
else
    echo "  ⚠️ 未找到 opencode;cc-connect 的 opencode agent 将不可用"
fi

# ---------- 2. 生成 config.toml ----------
echo "[2/5] 从现有 bot 配置生成 config.toml..."
python3 - <<'PYEOF' || exit 1
import json
import pathlib

BOT_CFG = pathlib.Path("/workspace/feishu-bot/feishu-bot-config.json")
OUT = pathlib.Path("/workspace/cc-connect/config.toml")

if not BOT_CFG.is_file():
    raise SystemExit(f"❌ 找不到现有 bot 配置: {BOT_CFG}")

bot = json.loads(BOT_CFG.read_text(encoding="utf-8"))
app_id = (bot.get("app_id") or "").strip()
app_secret = (bot.get("app_secret") or "").strip()
owner = (bot.get("owner_open_id") or "").strip()

if not app_id or not app_secret or "请填入" in app_id + app_secret:
    raise SystemExit("❌ 现有 bot 配置里的 app_id/app_secret 不完整")
if not owner:
    raise SystemExit("❌ owner_open_id 为空:请先在飞书给原 bot 发一条消息完成绑定再重跑")

config = f'''data_dir = "/workspace/cc-connect/data"

[[projects]]
name = "monkeycode"
admin_from = "{owner}"

  [projects.agent]
    type = "opencode"

    [projects.agent.options]
      work_dir = "/workspace"
      mode = "default"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "{app_id}"
      app_secret = "{app_secret}"
      allow_from = "{owner}"
'''

OUT.write_text(config, encoding="utf-8")
print(f"  ✅ 已写入 {OUT}(app_id {app_id[:12]}…, owner {owner[:12]}…)")
PYEOF

# ---------- 3. 生成启动器 + watchdog ----------
echo "[3/5] 写入启动器与 watchdog..."
cat > "$CC_DIR/run.sh" <<'RUNEOF'
#!/bin/bash
# cc-connect 启动器:把平台自带 opencode 挂进 PATH 后启动
OPENCODE_DIR=$(dirname "$(ls -d /root/.codingmatrix/bin/opencode-*/opencode 2>/dev/null | head -1)")
[ -n "$OPENCODE_DIR" ] && export PATH="$OPENCODE_DIR:$PATH"
export HOME="${HOME:-/root}"
cd /workspace/cc-connect
exec /workspace/cc-connect/cc-connect --config /workspace/cc-connect/config.toml
RUNEOF
chmod +x "$CC_DIR/run.sh"

rm -f "$CC_DIR/.stop"
nohup flock -n "$CC_DIR/.watchdog.lock" bash -c "
    while true; do
        [ -f '$CC_DIR/.stop' ] && { echo \"[\$(date '+%F %T')] 检测到 .stop,watchdog 退出\"; break; }
        bash '$CC_DIR/run.sh' >> '$LOG' 2>&1
        echo \"[\$(date '+%F %T')] cc-connect 退出,10 秒后重启\" >> '$LOG'
        sleep 10
    done
" >/dev/null 2>&1 &

# ---------- 4. 停自研 bot,释放飞书长连接 ----------
echo "[4/5] 停止自研 bot(释放飞书 App 长连接)..."
touch "$BOT_DIR/.stop"
pkill -f '^/workspace/feishu-bot/venv/bin/python' 2>/dev/null || true
# 同时停掉 bot 的 watchdog 循环(其命令行含 .stop 检测,由 .stop 文件自然退出)
sleep 3
if pgrep -f '^/workspace/feishu-bot/venv/bin/python' >/dev/null; then
    echo "  ⚠️ bot 进程仍在,强制结束"
    pkill -9 -f '^/workspace/feishu-bot/venv/bin/python' 2>/dev/null || true
    sleep 2
fi
echo "  ✅ bot 已停止"

# ---------- 5. 验证,失败自动回滚 ----------
echo "[5/5] 等待 cc-connect 建立飞书长连接(20 秒)..."
sleep 20

if pgrep -f '^/workspace/cc-connect/cc-connect' >/dev/null; then
    echo "  ✅ cc-connect 进程运行中"
    echo
    echo "=== 最近日志 ==="
    tail -15 "$LOG" 2>/dev/null || echo "(暂无日志)"
    echo "================"
    echo
    echo "✅ 部署完成。请在飞书里给机器人发一条消息测试(例如 /whoami 或 你好)。"
    echo "   若无响应,回滚:bash $CC_DIR/rollback.sh"
else
    echo "  ❌ cc-connect 未能启动,最近日志:"
    tail -30 "$LOG" 2>/dev/null || echo "(无日志)"
    echo
    echo "正在回滚到自研 bot..."
    bash "$CC_DIR/rollback.sh"
    exit 1
fi
