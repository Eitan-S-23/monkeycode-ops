#!/bin/bash
# cc-connect 回滚:停掉 cc-connect,恢复自研 feishu-bot
#
# 用法:bash /workspace/cc-connect/rollback.sh
#
# 注意:pkill 用 ^ 锚定可执行文件路径开头,只匹配 cc-connect 主进程。
# 裸写 pkill -f "cc-connect --config" 会命中 watchdog 的 bash -c 命令行
# (其中含同样字样),把拉起者也一起杀掉,且 pkill 自身命令行也可能被命中。
#
# 独立保活(keepalive.py)也要停:恢复后的自研 bot 自带内置保活循环,
# 两者同跑会每 12 小时各发起一轮 opencode 对话,重复且无意义。

set -uo pipefail

CC_DIR=/workspace/cc-connect
BOT_DIR=/workspace/feishu-bot

echo "[1/4] 停止 cc-connect..."
touch "$CC_DIR/.stop"  # 两个 watchdog 均以本文件为停止信号
pkill -f '^/workspace/cc-connect/cc-connect' 2>/dev/null || true
sleep 3
if pgrep -f '^/workspace/cc-connect/cc-connect' >/dev/null; then
    echo "  ⚠️ 进程仍在,强制结束"
    pkill -9 -f '^/workspace/cc-connect/cc-connect' 2>/dev/null || true
    sleep 2
fi
echo "  ✅ cc-connect 已停止"

echo "[2/4] 停止独立保活进程..."
# 模式串带 python3 前缀:watchdog 的 bash -c 里该路径两侧有引号,
# 且其 argv 为 "bash -c ...",故不会误命中拉起者;下面 pkill 也不匹配自身
pkill -f 'python3 /workspace/feishu-bot/keepalive\.py' 2>/dev/null || true
sleep 2
if pgrep -f 'python3 /workspace/feishu-bot/keepalive\.py' >/dev/null; then
    echo "  ⚠️ 保活仍在,强制结束"
    pkill -9 -f 'python3 /workspace/feishu-bot/keepalive\.py' 2>/dev/null || true
fi
echo "  ✅ 独立保活已停止(bot 恢复后由其内置保活接管)"

echo "[3/4] 等待飞书长连接释放(5 秒,避免旧连接未断导致新连接抢不到事件)..."
sleep 5

echo "[4/4] 恢复自研 bot(若本次部署曾停过它)..."
rm -f "$BOT_DIR/.stop"  # 清掉复用模式部署时留下的停止标记
if pgrep -f '^/workspace/feishu-bot/venv/bin/python' >/dev/null; then
    echo "  ➖ 自研 bot 本就在运行(新建机器人模式),无需恢复,保持原样"
else
    bash "$BOT_DIR/install.sh"
fi
