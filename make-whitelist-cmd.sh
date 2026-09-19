#!/bin/bash
# 生成"把飞书 open_id 写进容器 config.toml 白名单"的那条命令(在本机跑)
#
# 为什么要有它:
#   config.toml 在容器里,而改它要带引号 —— 直引号经飞书客户端会变成弯引号,
#   sed / python -c 那种写法到容器里必炸。故把补丁脚本 base64 后交出去:
#   base64 字符集是 A-Za-z0-9+/= ,不含引号,飞书怎么转都不影响。
#
# 用法: bash make-whitelist-cmd.sh --codex ou_xxx --claude ou_yyy
#
#   两个参数都可不给其中之一,但至少要给一个;只给的那个 project 才会被改。
#
# 为什么必须分开传:
#   飞书的 open_id 是**按应用隔离**的 —— 同一个人在不同 App 下的 open_id 不同。
#   新机器人回给你的那串,拿去填 claude 的 allow_from 会被判成"外人"。
#
# 补丁做什么(幂等,可重复跑):
#   每个被点名的 project,在 [[projects]] 顶层补 admin_from、在它自己的
#   [projects.platforms.options] 里补 allow_from;已有同名键则改值而不重复插入。

set -uo pipefail

CODEX_ID=""
CLAUDE_ID=""

usage() {
    echo "用法: bash make-whitelist-cmd.sh --codex ou_xxx [--claude ou_yyy]"
    echo "      至少给一个;只给的那个 project 才会被改。"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --codex|--claude)
            [ $# -ge 2 ] || { echo "❌ $1 后面要跟一个 open_id"; usage; exit 1; }
            if [ "$1" = "--codex" ]; then CODEX_ID="$2"; else CLAUDE_ID="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "❌ 未知参数: $1"; usage; exit 1 ;;
    esac
done

# 只允许 open_id 的合法字符:顺带挡住"从聊天里粘过来时夹带了引号或空格"这种最常见的手误
check_id() {
    local label="$1" v="$2"
    case "$v" in
        ou_*) ;;
        *) echo "❌ $label 必须是 ou_ 开头的 open_id(现在给的是: ${v:-<空>})"; exit 1 ;;
    esac
    if ! printf '%s' "$v" | grep -qE '^ou_[A-Za-z0-9_-]+$'; then
        echo "❌ $label 含非法字符(只应有字母/数字/下划线/连字符): $v"
        exit 1
    fi
}
[ -n "$CODEX_ID" ]  && check_id "--codex"  "$CODEX_ID"
[ -n "$CLAUDE_ID" ] && check_id "--claude" "$CLAUDE_ID"
if [ -z "$CODEX_ID" ] && [ -z "$CLAUDE_ID" ]; then
    echo "❌ 至少要给一个 --codex / --claude"; usage; exit 1
fi

# 拼成 python 字典字面量;键就是 config.toml 里的 project 名
IDS=""
[ -n "$CODEX_ID" ]  && IDS="$IDS\"codex\": \"$CODEX_ID\", "
[ -n "$CLAUDE_ID" ] && IDS="$IDS\"claude\": \"$CLAUDE_ID\", "

PY=$(cat <<PYEOF
import pathlib, re, sys

P = pathlib.Path("/workspace/cc-connect/config.toml")
# 只改这里点名的 project,其余 project 一个字不动
IDS = {$IDS}

text = P.read_text(encoding="utf-8")
lines = text.splitlines()

ADMIN_RE = re.compile(r"^admin_from\s*=")
ALLOW_RE = re.compile(r"^\s*allow_from\s*=")
NAME_RE = re.compile(r'^name\s*=\s*"([^"]*)"\s*$')

def blocks(lines):
    """切出每个 [[projects]] 的文本区块,顺带定位它的 name 行。

    与 apply-providers.py / set-heartbeat.py 同一套规则:区块到下一个
    [[projects]] 为止,name 只在本区块的第一个子表头之前找 —— 否则会误取
    providers 里的 name。
    """
    starts = [i for i, ln in enumerate(lines) if ln.strip() == "[[projects]]"]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        name, nl = "", None
        for i in range(s + 1, e):
            t = lines[i].strip()
            if t.startswith("["):
                break
            m = NAME_RE.match(t)
            if m:
                name, nl = m.group(1), i
                break
        out.append((name, s, e, nl))
    return out

blks = blocks(lines)
have = [n for n, _, _, _ in blks]
missing = [k for k in IDS if k not in have]
if missing:
    print(f"❌ config.toml 里没有这些 project: {', '.join(missing)}")
    print(f"   (现有的: {', '.join(have) if have else '无'}) —— 已放弃,原文件未动")
    sys.exit(1)

changed = []
# 从后往前改:插行会让后面区块的下标失效
for name, s, e, nl in reversed(blks):
    if name not in IDS:
        continue
    uid = IDS[name]
    seg = lines[s:e]
    admin_done = any(ADMIN_RE.match(l) for l in seg)
    allow_done = any(ALLOW_RE.match(l) for l in seg)
    new = []
    for i, ln in enumerate(seg):
        if admin_done and ADMIN_RE.match(ln):
            ln = f'admin_from = "{uid}"'
            changed.append(f"{name}: admin_from = 改值")
        elif allow_done and ALLOW_RE.match(ln):
            ln = f'      allow_from = "{uid}"'
            changed.append(f"{name}: allow_from = 改值")
        new.append(ln)
        # admin_from 是 [[projects]] 的键,插在 name 行之后、第一个子表头之前
        if not admin_done and nl is not None and i == nl - s:
            new.append(f'admin_from = "{uid}"')
            changed.append(f"{name}: admin_from = 插入")
        # allow_from 是平台的键,插在 app_secret 之后。
        # 别写"还要看下一行"那种前瞻:app_secret 正好是文件末行时前瞻会失败,
        # 并**静默漏掉**这个平台 —— 这个 bug 被本地验证脚本抓到过一次。
        if not allow_done and re.match(r'^\s*app_secret\s*=', ln):
            new.append(f'      allow_from = "{uid}"')
            changed.append(f"{name}: allow_from = 插入")
    lines[s:e] = new

if not changed:
    print("❌ 没有任何改动(既没找到可替换的键,也没找到可插入的位置),原文件未动")
    sys.exit(1)

new_text = "\n".join(lines) + "\n"

# 落盘前自检:写坏一份正在跑的配置 = 机器人整体失联,而现场在容器里、要靠飞书绕一圈排查,
# 所以这里两道独立检查都过才落盘,任何一道不过就原文件不动。
errs = []
for name, s, e, nl in blocks(lines):
    uid = IDS.get(name)
    if not uid:
        continue
    # ① 结构检查:admin_from 恰好在 [[projects]] 顶层、allow_from 恰好落在平台的 options 里
    head_end = next((i for i in range(s + 1, e) if lines[i].strip().startswith("[")), e)
    adm = [l for l in lines[s + 1:head_end] if ADMIN_RE.match(l)]
    if adm != [f'admin_from = "{uid}"']:
        errs.append(f"{name}: [[projects]] 顶层应有且仅有 1 行 admin_from = \"{uid}\",实得 {adm}")
    try:
        ptop = next(i for i in range(s + 1, e) if lines[i].strip() == "[projects.platforms.options]")
    except StopIteration:
        errs.append(f"{name}: 找不到 [projects.platforms.options]")
        continue
    alw = [l for l in lines[ptop + 1:e] if ALLOW_RE.match(l)]
    if not alw or any(l != f'      allow_from = "{uid}"' for l in alw):
        errs.append(f"{name}: 平台 options 里应有且仅有 allow_from = \"{uid}\"(可多处),实得 {alw}")

# ② TOML 解析检查:python 3.11+ 才有 tomllib,老版本降级为只报一声
try:
    import tomllib
except ImportError:
    print("  ⚠️ 当前 python 无 tomllib(需 3.11+),只做了结构检查")
else:
    try:
        doc = tomllib.loads(new_text)
    except Exception as ex:
        errs.append(f"改完不是合法 TOML: {ex}")
    else:
        for pr in doc.get("projects") or []:
            uid = IDS.get(pr.get("name"))
            if uid and pr.get("admin_from") != uid:
                errs.append(f"{pr.get('name')}: 解析后 admin_from = {pr.get('admin_from')!r},期望 {uid!r}")

if errs:
    print("❌ 自检未通过,已放弃,原文件未动:")
    for x in errs:
        print(f"   - {x}")
    sys.exit(1)

P.with_suffix(".toml.pre-whitelist").write_text(text, encoding="utf-8")
P.with_suffix(".toml.new").write_text(new_text, encoding="utf-8")
P.with_suffix(".toml.new").replace(P)

print("✅ 白名单已写入(改前内容备份在 config.toml.pre-whitelist)")
for c in changed:
    print(f"   - {c}")
for name, s, e, nl in blocks(lines):
    uid = IDS.get(name)
    if not uid:
        continue
    print(f"   {name}: admin_from={uid}")
print("   生效需重启:pkill -f '^/workspace/cc-connect/cc-connect'  # watchdog 10 秒内自动拉起")
PYEOF
)

B64=$(printf '%s' "$PY" | gzip -9c | base64 -w0)
CMD="echo $B64 | base64 -d | gunzip | python3"

# 命令体要过剪贴板,必须纯 ASCII —— 这一条已经在 .verify-upload.sh 里作为硬断言,
# 这里再自查一次,免得又出现"提示文字变乱码"的现场。
# 用 [^ -~] 而不是 grep -P:这台机器的 locale 下 grep -P 会直接报错退出,
# 而"报错退出"和"没找到"在 if 里长得一模一样 —— 断言会静默变成假通过。
if printf '%s' "$CMD" | LC_ALL=C grep -q '[^ -~]'; then
    echo "❌ 命令体含非 ASCII 字符,过剪贴板会变乱码"; exit 1
fi

echo "───────────────────────────────────────────────────────────"
[ -n "$CODEX_ID" ]  && echo " codex  : $CODEX_ID"
[ -n "$CLAUDE_ID" ] && echo " claude : $CLAUDE_ID"
echo " 命令长度 : ${#CMD} 字符"
echo " 作用     : 给上面这些 project 补 admin_from 与 allow_from(其余 project 不动)"
echo "───────────────────────────────────────────────────────────"
echo "=== 下面这一整行就是命令(已复制到剪贴板,粘给原命令机器人) ==="
echo "$CMD"
echo
echo "=== 成功时它会回显:白名单已写入 + 每个 project 的实际取值 ==="
echo

# WL_NO_CLIP=1 时只打印不复制:本地验证脚本要反复跑它,不能每次都把剪贴板顶掉
if [ "${WL_NO_CLIP:-}" != "1" ] && command -v clip.exe >/dev/null 2>&1; then
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
