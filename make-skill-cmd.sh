#!/bin/bash
# 生成"把 feishu-send skill 装进容器"的那条命令(在本机跑)
#
# 为什么要有它:
#   一份 skill 文件,两个 agent 要能从**任意目录**启动时都读到,而两者的技能目录
#   约定不同(见下面"三个落点")。手打 cp 容易漏,漏了的表现还是静默的 ——
#   agent 照常工作,只是永远不发文件,你甚至不知道它没读到说明书。
#   所以落点写死在这里,由本地验证脚本连着跑一遍。
#
# 用法: bash make-skill-cmd.sh
#       WL_NO_CLIP=1 只打印不复制(本地验证用)
#
# 三个落点(前两个是 claude 的默认技能目录,后两个是 codex 的):
#   $HOME/.claude/skills/feishu-send/SKILL.md    ← claude 默认读这里
#   $HOME/.codex/skills/feishu-send/SKILL.md     ← codex 在 CODEX_HOME 未设时的回退
#   /workspace/codex-home/skills/feishu-send/    ← 容器里 codex 实际读的那个
#
# 第三条之所以写成**字面路径**而不是 $CODEX_HOME:这个变量是 cc-connect 给 codex
#   子进程设的(agent/codex/codex.go:507),执行本命令的那个 shell 未必有 ——
#   指望它等于把 skill 装到不确定的地方。所以每次生成时从 deploy-codex.sh 里
#   现读 codex_home,配置改了重新生成即同步。
#
#   顺带纠正一个流传的说法:cc-connect 源码里 codexSkillDirs() 把 $HOME/.claude/skills
#   也列了出来,看起来"一份就够"。但那是**给 cc-connect 自己的 UI 列目录用的**,
#   不是 codex 本体的扫描路径 —— codex 二进制里只有 CODEX_HOME/skills、/.codex/skills
#   和 ./skills/,没有 .claude/skills。据此按两套目录装,不赌。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/skills/feishu-send/SKILL.md"
export WL_NO_CLIP="${WL_NO_CLIP:-}"

[ -f "$SRC" ] || { echo "❌ 找不到 $SRC"; exit 1; }

# codex_home 在 deploy-codex.sh 的 heredoc 里带着前导空格,锚 ^ 会取不到
CH="$(sed -n 's/^[[:space:]]*codex_home *= *"\([^"]*\)".*/\1/p' "$HERE/deploy-codex.sh" | head -1)"
[ -n "$CH" ] || { echo "❌ 从 deploy-codex.sh 里读不到 codex_home,不敢猜 codex 的技能目录"; exit 1; }

SIZE="$(wc -c < "$SRC" | tr -d ' ')"
MD5="$(md5sum "$SRC" | cut -d' ' -f1)"

# 先 gzip 再 base64:一是短,二是 base64 字符集 A-Za-z0-9+/= 里没有引号,
# 而引号正是过飞书时会被换成弯引号、把命令毁掉的那个字符。
B64="$(gzip -9c "$SRC" | base64 -w0)"

TMP=/tmp/feishu-send-SKILL.md
# ${HOME:-/root} 而不是 $HOME:HOME 若为空,前者会拼成 /.claude/... 写到文件系统根。
# 不带引号的 ${VAR:-默认值} 展开不需要引号,也就绕开了飞书那道引号转换。
H='${HOME:-/root}'

# 拼命令。全篇不出现任何引号 —— 连 [ -n "$VAR" ] 那种写法也一并避开,
# 这里的空值保护靠 ${VAR:-默认值},既不需要引号,空值时也确实是默认值。
CMD="echo $B64 | base64 -d | gunzip > $TMP.new"
CMD="$CMD && mkdir -p $H/.claude/skills/feishu-send $H/.codex/skills/feishu-send $CH/skills/feishu-send"
CMD="$CMD && cp $TMP.new $H/.claude/skills/feishu-send/SKILL.md"
CMD="$CMD && cp $TMP.new $H/.codex/skills/feishu-send/SKILL.md"
CMD="$CMD && cp $TMP.new $CH/skills/feishu-send/SKILL.md"
CMD="$CMD && rm -f $TMP.new"
CMD="$CMD && echo HOME=\$HOME CODEX_HOME=\$CODEX_HOME"
CMD="$CMD && md5sum $H/.claude/skills/feishu-send/SKILL.md"
CMD="$CMD && md5sum $H/.codex/skills/feishu-send/SKILL.md"
CMD="$CMD && md5sum $CH/skills/feishu-send/SKILL.md"

# 命令体要过剪贴板,必须纯 ASCII。用 [^ -~] 而不是 grep -P:
# 这台机器的 locale 下 grep -P 会直接报错退出,而"报错退出"和"没找到"在 if 里
# 长得一模一样 —— 断言会静默变成假通过。
if printf '%s' "$CMD" | LC_ALL=C grep -q '[^ -~]'; then
    echo "❌ 命令体含非 ASCII 字符,过剪贴板会变乱码"; exit 1
fi
# 顺带把"不许有引号"也钉死:这是飞书那一道转换的直接触发条件
case "$CMD" in
    *'"'*|*"'"*) echo "❌ 命令体含引号,过飞书会被换成弯引号"; exit 1 ;;
esac

echo "───────────────────────────────────────────────────────────"
echo " 源文件   : $SRC"
echo " 字节数   : $SIZE"
echo " md5      : $MD5"
echo " 命令长度 : ${#CMD} 字符"
echo " 落点     : \$HOME/.claude/skills/  \$HOME/.codex/skills/  $CH/skills/"
echo "───────────────────────────────────────────────────────────"
echo "=== 下面这一整行就是命令(已复制到剪贴板,粘给原命令机器人) ==="
echo "$CMD"
echo
echo "=== 成功时回显 3 行相同的 md5,应当等于上面那个 $MD5 ==="
echo "=== 第一行会是 HOME=... CODEX_HOME=...,核对 HOME 是不是 /root ==="
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
