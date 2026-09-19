#!/bin/bash
# 本地生成"把文件上传到容器"的一行命令(在你自己电脑上跑,不在容器里跑)
#
# 为什么要有这个脚本:
#   bots.env / config.toml 里含 app_secret 与 provider key。这行命令本质上就是
#   把密钥编码后带过去。脚本只往你本机的终端和剪贴板输出,不往对话里写。
#
# 用法(Git Bash / WSL / macOS 终端):
#     bash make-upload-cmd.sh bots.env
#     bash make-upload-cmd.sh providers.toml --no-split
#     bash make-upload-cmd.sh providers.toml --copy 2
#     位置参数 = 本地文件,以及可选的容器内目标路径
#     --no-split = 不分片,只输出一整条命令(给平台 Web 终端用)
#     --copy N   = 只把第 N 条放进剪贴板,不打印命令体
#
# 三种投递方式:
#     飞书单条消息上限约 8192 字符,超了必须切片、一片发一条消息。切片时默认只把
#     第 1 片放进剪贴板,第 2 片开始得自己选 —— 用 --copy 2 单独放一次即可,
#     全程不用手工选中长文本。
#       走飞书(短文件) → 默认,一条进剪贴板
#       走飞书(长文件) → 默认看片数,再 --copy 2 / --copy 3 逐片放剪贴板
#       走 Web 终端    → --no-split,整条进剪贴板,粘一次完事

set -uo pipefail

SRC=""
DST=""
SPLIT=1
COPY_N=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-split) SPLIT=0; shift ;;
        --copy)
            [ -n "${2:-}" ] || { echo "❌ --copy 需要一个序号,如 --copy 2"; exit 1; }
            COPY_N="$2"; shift 2 ;;
        -h|--help)
            echo "用法: bash make-upload-cmd.sh <本地文件> [容器内目标路径] [--no-split] [--copy N]"
            echo "例:   bash make-upload-cmd.sh providers.toml              # 打印各片,第 1 片进剪贴板"
            echo "      bash make-upload-cmd.sh providers.toml --no-split   # 整条一条,给 Web 终端"
            echo "      bash make-upload-cmd.sh providers.toml --copy 2     # 只把第 2 片放剪贴板,不打印"
            exit 0 ;;
        *)
            if [ -z "$SRC" ]; then
                SRC="$1"
            elif [ -z "$DST" ]; then
                DST="$1"
            else
                echo "❌ 多余的位置参数: $1"; exit 1
            fi
            shift ;;
    esac
done

if [ -z "$SRC" ]; then
    echo "用法: bash make-upload-cmd.sh <本地文件> [容器内目标路径] [--no-split] [--copy N]"
    echo "例:   bash make-upload-cmd.sh bots.env"
    echo "      bash make-upload-cmd.sh providers.toml --copy 2"
    exit 1
fi
[ -f "$SRC" ] || { echo "❌ 找不到本地文件: $SRC"; exit 1; }

NAME="$(basename "$SRC")"
[ -n "$DST" ] || DST="/workspace/cc-connect/$NAME"

SIZE="$(wc -c < "$SRC" | tr -d ' ')"
# 用 md5 而不是 sha:容器和 Git Bash 都自带 md5sum,拿来比对够用,少一层依赖
MD5="$(md5sum "$SRC" | cut -d' ' -f1)"

# 先压缩再编码。TOML/JSON/脚本这类文本能压到 1/8 ~ 1/10,直接把"发不出去"
# 变成"一条消息发得完" —— 纯 base64 时 22KB 的文件就已是 3 万字符,
# 远超单条消息上限。gzip 缺失时退回纯 base64,不因为一个可选优化就罢工。
USE_GZIP=0
if command -v gzip >/dev/null 2>&1; then
    USE_GZIP=1
    B64="$(gzip -9c "$SRC" | base64 -w0)"
else
    B64="$(base64 -w0 "$SRC")"
fi

# 单条消息上限约 8192 字符,留出命令本身的余量。--no-split 时压根不分片:
# 走 Web 终端没有这个限制,切了反而要多粘几次。
LIMIT=7000
LEN=${#B64}
CHUNKS=0
if [ "$SPLIT" = "1" ] && [ "$LEN" -gt "$LIMIT" ]; then
    CHUNKS=$(( (LEN + LIMIT - 1) / LIMIT ))
fi

# 命令里刻意不出现任何引号:base64 字符集是 A-Za-z0-9+/= ,在 bash 里无需引号,
# 也就绕开了飞书客户端把直引号变成弯引号导致命令跑不通的坑。
# 先备份再覆盖,.bak 用固定名(避免 $(date) 引入括号)。
DECODE="base64 -d"
[ "$USE_GZIP" = "1" ] && DECODE="base64 -d | gunzip"

echo "───────────────────────────────────────────────────────────"
echo " 本地文件 : $SRC"
echo " 目标路径 : $DST"
echo " 字节数   : $SIZE"
echo " md5      : $MD5"
echo " 传输方式 : $([ "$USE_GZIP" = "1" ] && echo "gzip + base64" || echo "纯 base64")"
[ "$SPLIT" = "0" ] && echo " 投递方式 : 不分片(平台 Web 终端;编码后 $LEN 字符)"
[ "$CHUNKS" != "0" ] && echo " ⚠️ 分片   : $CHUNKS 片,每片 ≤$LIMIT 字符,按顺序各发一条消息"
echo "───────────────────────────────────────────────────────────"
echo
if [ "$SPLIT" = "1" ] && [ "$SIZE" -gt 8192 ] && [ "$CHUNKS" = "0" ]; then
    echo "⚠️ 文件 $SIZE 字节,编码后 $LEN 字符 —— 飞书单条消息可能被截断,"
    echo "   建议加 --no-split 改走平台 Web 终端粘贴。"
    echo
fi

# 先把每条命令算出来,再决定打印什么、哪一条进剪贴板。
# 分片模式下每片必须是**独立的一条命令** —— 拼成长命令等于没分片;
# 逐片追加到 .b64,最后一片才解码落盘。
# 落盘一律走 "先解到 $DST.new,成功才 mv":直接 `> $DST` 的话,重定向会**先**
# 把目标文件截断,gunzip 再失败就只剩一个空文件 —— 现场只有一句 gzip 报错,
# 看不出原来那份已经被清空了(这次就是这么丢的 providers.toml)。
CHUNK_LINES=()
if [ "$CHUNKS" = "0" ]; then
    CHUNK_LINES[0]="cp -a $DST $DST.bak 2>/dev/null ; echo $B64 | $DECODE > $DST.new && chmod 600 $DST.new && mv $DST.new $DST && wc -c < $DST && md5sum $DST ; rm -f $DST.new"
else
    i=0
    while [ "$i" -lt "$CHUNKS" ]; do
        part="$(printf '%s' "$B64" | cut -c $(( i * LIMIT + 1 ))-$(( (i + 1) * LIMIT )))"
        if [ "$i" = "0" ]; then
            line="echo -n $part > $DST.b64"
        else
            line="echo -n $part >> $DST.b64"
        fi
        if [ "$i" = "$(( CHUNKS - 1 ))" ]; then
            line="$line ; cp -a $DST $DST.bak 2>/dev/null ; cat $DST.b64 | $DECODE > $DST.new && chmod 600 $DST.new && mv $DST.new $DST && rm -f $DST.b64 && wc -c < $DST && md5sum $DST ; rm -f $DST.new"
        fi
        # 每片先自检前面几片是否发全,不全就当场停住。少了这道闸,"把第 2 片
        # 单独重发一次"会先新建只含半截 base64 的 .b64,解出来不是 gzip →
        # 而 `> $DST` 的截断发生在 gunzip 之前,目标文件就被清空了 —— 现场只留
        # 一句 "not in gzip format",看不出是哪一步、更看不出文件已经没了。
        if [ "$i" != "0" ]; then
            # 命令体必须**纯 ASCII**。它要经 Windows 剪贴板走一道(clip.exe 是控制台
            # 程序,按 OEM 代码页转码),实测中文和 emoji 都会被换成 U+FFFD,而且时好
            # 时坏 —— 前一版这里写了中文提示,粘出来就成了乱码。宁可用一行英文,也不要
            # 一条会自毁的命令。脚本自己在本地打印的中文不受影响(那是终端输出)。
            line="[ \"\$(wc -c 2>/dev/null < $DST.b64 || echo 0)\" = \"$(( i * LIMIT ))\" ] || { echo \"!! chunk $(( i + 1 )) aborted: b64 holds \$(wc -c 2>/dev/null < $DST.b64 || echo 0) bytes, expected $(( i * LIMIT )) - earlier chunks are missing. Target file untouched.\"; exit 1; } ; $line"
        fi
        CHUNK_LINES[$i]="$line"
        i=$((i + 1))
    done
fi
TOTAL=${#CHUNK_LINES[@]}

# 默认把第 1 条放进剪贴板;--copy N 指定放第 N 条(从 1 数),且不再打印命令体 ——
# 命令内容本身就是密钥,没必要为了看一眼再铺满一屏。
PICK=1
[ -n "$COPY_N" ] && PICK="$COPY_N"
if [ "$PICK" -lt 1 ] || [ "$PICK" -gt "$TOTAL" ]; then
    echo "❌ --copy $PICK 越界:本次共 $TOTAL 条"
    exit 1
fi

if [ -n "$COPY_N" ]; then
    echo "=== 第 $PICK/$TOTAL 条已放进剪贴板,直接粘到飞书发出即可 ==="
else
    if [ "$CHUNKS" = "0" ]; then
        echo "=== 下面这一整行就是命令(已复制到剪贴板,直接粘) ==="
        echo
        echo "${CHUNK_LINES[0]}"
        echo
    else
        echo "=== 下面每片各发一条消息,必须按顺序 ==="
        echo "=== (第 1 片先清空临时文件,最后一片才解码落盘) ==="
        echo
        i=0
        while [ "$i" -lt "$TOTAL" ]; do
            echo "----- 第 $(( i + 1 ))/$TOTAL 片 -----"
            echo "${CHUNK_LINES[$i]}"
            echo
            i=$((i + 1))
        done
        echo "提示:全部执行完应得到 $TOTAL 行相同的 md5。缺片时 md5 对不上,重发缺的那片即可。"
        echo
    fi
fi

echo "=== 容器里执行成功后,核对:字节数应为 $SIZE,md5 应为 $MD5 ==="
echo

CMD="${CHUNK_LINES[$(( PICK - 1 ))]}"

# 复制到剪贴板:Windows 用 clip.exe, macOS 用 pbcopy, Linux 用 xclip
if command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$CMD" | clip.exe || { echo "⚠️ 复制失败,请手工选中上面那行"; exit 1; }
    # 剪贴板不是无损通道:clip.exe 是控制台程序,按 OEM 代码页转码,编不出的字符
    # 会被替换掉。写完必须读回来比一次 —— 否则用户粘出去的是被改过的命令,而现场
    # 一句话都不会提示。排查"命令到了容器里行为诡异"这种问题的代价,远高于这一次读回。
    if command -v powershell.exe >/dev/null 2>&1; then
        BACK="$(powershell.exe -NoProfile -Command 'Get-Clipboard -Raw' 2>/dev/null | tr -d '\r\n')"
        if [ "$BACK" = "$CMD" ]; then
            echo "✅ 已复制到剪贴板(已读回逐字核对)"
        else
            echo "⚠️ 剪贴板读回来和命令不一致(长度 $((${#CMD} - ${#BACK})) 字符的差):别直接粘。"
            echo "   去掉 --copy 重跑本脚本,手工选中那一整行再复制。"
            exit 1
        fi
    else
        echo "✅ 已复制到剪贴板"
    fi
elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$CMD" | pbcopy && echo "✅ 已复制到剪贴板"
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$CMD" | xclip -selection clipboard && echo "✅ 已复制到剪贴板"
else
    echo "⚠️ 未找到剪贴板工具,请手工选中上面那行命令"
fi
