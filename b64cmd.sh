#!/bin/bash
# 把一条命令包成"能安全过飞书"的一行(在本机跑)
#
# 为什么需要:
#   飞书客户端会把直引号 `"` `'` 变成弯引号 “ ” ‘ ’,经过它的命令只要带引号,
#   到容器里必炸;中文和 emoji 过剪贴板还会变 U+FFFD。base64 字符集是
#   A-Za-z0-9+/=,不含引号,所以把整条命令 gzip+base64 再交出去最稳。
#
# 用法:
#   bash b64cmd.sh 'rm -f /workspace/x "带引号" 也行'
#   bash b64cmd.sh -f probe.sh          # 从文件读(多行命令用这个)
#   WL_NO_CLIP=1 只打印不复制

set -uo pipefail
export WL_NO_CLIP="${WL_NO_CLIP:-}"

if [ "${1:-}" = "-f" ]; then
    [ $# -ge 2 ] || { echo "❌ -f 后面要跟文件名"; exit 1; }
    SRC="$2"
    [ -f "$SRC" ] || { echo "❌ 找不到文件: $SRC"; exit 1; }
    BODY="$(cat "$SRC")"
else
    [ $# -ge 1 ] || { echo "用法: bash b64cmd.sh '<命令>' | -f <脚本文件>"; exit 1; }
    BODY="$1"
fi

[ -n "$BODY" ] || { echo "❌ 命令是空的"; exit 1; }

B64=$(printf '%s' "$BODY" | gzip -9c | base64 -w0)
CMD="echo $B64 | base64 -d | gunzip | bash"

# 命令体要过剪贴板,必须纯 ASCII;base64 天然满足,这里只是把它变成硬断言。
# 用 [^ -~] 而不是 grep -P:这台机器的 locale 下 grep -P 会直接报错退出,
# 而"报错退出"和"没找到"在 if 里长得一模一样 —— 断言会静默变成假通过。
if printf '%s' "$CMD" | LC_ALL=C grep -q '[^ -~]'; then
    echo "❌ 命令体含非 ASCII 字符,过剪贴板会变乱码"; exit 1
fi

echo "───────────────────────────────────────────────────────────"
echo " 原文长度 : ${#BODY} 字符"
echo " 包装后   : ${#CMD} 字符"
echo "───────────────────────────────────────────────────────────"
echo "=== 下面这一整行就是命令 ==="
echo "$CMD"
echo

if [ "$WL_NO_CLIP" != "1" ] && command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$CMD" | clip.exe || { echo "⚠️ 复制失败,请手工选中上面那行"; exit 1; }
    if command -v powershell.exe >/dev/null 2>&1; then
        BACK="$(powershell.exe -NoProfile -Command 'Get-Clipboard -Raw' 2>/dev/null | tr -d '\r\n')"
        if [ "$BACK" = "$CMD" ]; then
            echo "✅ 已复制到剪贴板(已读回逐字核对)"
        else
            echo "⚠️ 剪贴板读回来和命令不一致,别直接粘"; exit 1
        fi
    fi
fi
