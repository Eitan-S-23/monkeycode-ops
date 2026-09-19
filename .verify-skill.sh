#!/bin/bash
# 本地验证 skills/feishu-send/SKILL.md 与 make-skill-cmd.sh
#
# 这个 skill 是给容器里的 claude / codex 看的说明书,它出错的代价很特别:
#   agent 会照着它执行 —— 写错一个选项名,现场表现是"命令不认",而 agent 大概率
#   不会回头怀疑说明书,而是得出结论"发不了文件"。这正是之前 codex 那套
#   "我没有网络、没有凭据、没有接口"的来源(三条全不成立,但听起来很合理)。
# 所以断言全部对着**真实二进制与源码**,不核对我自己写的表。

set -uo pipefail

export WL_NO_CLIP=1
export PYTHONIOENCODING=utf-8
w() { cygpath -m "$1"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HERE/skills/feishu-send/SKILL.md"
GEN="$HERE/make-skill-cmd.sh"
SRC="$HERE/.cache/cc-connect-src"
BIN="${BIN:-/d/github/my/cc-connect-thread-guard/build/cc-connect}"
PY="${PY:-python}"
VD="$HERE/.verify-skill"
SB="$VD/sb"

rm -rf "$VD"; mkdir -p "$SB"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

[ -f "$SKILL" ] || { echo "❌ 找不到 $SKILL"; exit 1; }

# ---------- 1. frontmatter 得是 agent 认的格式 ----------
echo "══ 1. frontmatter(两个 agent 都按这个解析)══"
"$PY" - "$(w "$SKILL")" <<'PYEOF'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
bad = []
if not t.startswith("---\n"):
    bad.append("文件不是以 --- 开头,YAML frontmatter 不会被解析")
m = re.match(r"---\n(.*?)\n---\n", t, re.S)
fm, body = "", t
if not m:
    bad.append("找不到 frontmatter 的结束 ---")
else:
    fm, body = m.group(1), t[m.end():]
name = re.search(r"^name:\s*(\S+)\s*$", fm, re.M)
desc = re.search(r"^description:\s*(.+)$", fm, re.M)
if not name:
    bad.append("frontmatter 缺 name")
elif name.group(1) != p.parent.name:
    bad.append(f"name={name.group(1)!r} 与目录名 {p.parent.name!r} 不一致(skill 靠目录名索引)")
if not desc:
    bad.append("frontmatter 缺 description —— 没有它 agent 不知道何时该用这个 skill")
elif len(desc.group(1)) < 30:
    bad.append(f"description 只有 {len(desc.group(1))} 字,触发条件写不清")
if len(body) < 500:
    bad.append(f"正文只有 {len(body)} 字,像是没写完")
print("  ✅ frontmatter 合法:name 与目录名一致,description 交代了触发条件" if not bad
      else "  ❌ " + "; ".join(bad))
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 2. 提到的每个选项都必须真实存在 ----------
# 挡的是"凭印象写选项":把 --file 写成 --attach,agent 照着敲只会得到一句 usage,
# 然后它大概率会放弃,而不是去查 help。
echo "══ 2. 正文提到的 --选项 都存在于真实 CLI ══"
if [ ! -x "$BIN" ]; then
    fail "找不到 cc-connect 二进制: $BIN"
else
    HELP_TXT="$("$BIN" send --help 2>&1)" "$PY" - "$(w "$SKILL")" <<'PYEOF'
import os, pathlib, re, sys
skill = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
help_txt = os.environ["HELP_TXT"]
flags = sorted(set(re.findall(r"--[a-z][a-z-]+", skill)))
missing = [f for f in flags if f not in help_txt]
print(f"  正文提到 {len(flags)} 个选项: {' '.join(flags)}")
print("  ✅ 全部存在" if not missing else f"  ❌ help 里没有: {missing} —— agent 照着敲会失败")
sys.exit(1 if missing else 0)
PYEOF
    [ $? = 0 ] || FAIL=1
fi
echo

# ---------- 3. 引用的报错必须逐字来自源码 ----------
echo "══ 3. 正文引用的报错逐字来自源码(不是我编的措辞)══"
if [ ! -d "$SRC" ]; then
    echo "  ⚠️  没有缓存源码(.cache/cc-connect-src),本节跳过 —— 报错文案无法核对"
else
    "$PY" - "$(w "$SKILL")" "$(w "$SRC")" <<'PYEOF'
import pathlib, re, sys
skill = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blob = "\n".join(f.read_text(encoding="utf-8", errors="replace")
                 for f in pathlib.Path(sys.argv[2]).rglob("*.go"))
# 正文里用反引号框起来、且含空格的纯 ASCII 串 = 报错文案。两个条件缺一不可:
# 环境变量表里的 `CC_PROJECT` 没有空格,选项表里的 `--file <绝对路径>` 含中文,
# 都不该被当成"报错文案"去源码里找。
quoted = re.findall(r"^\| `([^`]+)` \|", skill, re.M)
quoted = [q for q in quoted if " " in q and all(ord(c) < 128 for c in q)]
bad, checked, brief = [], [], []
for q in quoted:
    # 正文用 ... 代表省略的运行时值(如 socket 路径),比对到省略号为止的前缀
    probe = q.split("...")[0].strip() if "..." in q else q
    if len(probe) < 20:
        brief.append(q); continue
    checked.append(q)
    if probe not in blob:
        bad.append(q)
print(f"  筛出 {len(quoted)} 条报错文案,{len(checked)} 条按前缀核对、{len(brief)} 条太短跳过")
if len(checked) < 3:
    bad.append(f"只核对了 {len(checked)} 条 —— 报错表被改动过,断言覆盖面不够")
for q in checked:
    print(f"    {'OK  ' if q not in bad else 'FAIL'} {q[:72]}")
print("  ✅ 逐字命中源码" if not bad else f"  ❌ {bad}")
sys.exit(1 if bad else 0)
PYEOF
    [ $? = 0 ] || FAIL=1
fi
echo

# ---------- 4. 源码仍在注入环境变量(核心前提) ----------
echo "══ 4. cc-connect 仍在注入 CC_* 与 PATH(核心前提)══"
if [ ! -f "$SRC/core/engine.go" ]; then
    fail "找不到 $SRC/core/engine.go"
else
    for pat in 'CC_PROJECT=' 'CC_SESSION_KEY=' 'CC_DATA_DIR=' 'filepath.Dir(exePath)'; do
        grep -qF -- "$pat" "$SRC/core/engine.go" && ok "engine.go 仍有 $pat" \
            || fail "engine.go 里没有 $pat —— skill 的『不用传参』前提失效了"
    done
    grep -qF 'SetSessionEnv(envVars)' "$SRC/core/engine.go" \
        && ok "envVars 确实交给了 SetSessionEnv(不是拼了个没人用的切片)" \
        || fail "envVars 没有被 SetSessionEnv 消费"
fi
echo

# ---------- 5. 正文里的路径与数字必须与部署脚本/源码一致 ----------
echo "══ 5. 路径与数字和部署脚本、源码一致 ══"
# codex_home 那行在 heredoc 里带前导空格,锚 ^ 会取不到
CH="$(sed -n 's/^[[:space:]]*codex_home *= *"\([^"]*\)".*/\1/p' "$HERE/deploy-codex.sh" | head -1)"
[ -n "$CH" ] && ok "deploy-codex.sh 里 codex_home = $CH" \
    || fail "取不到 codex_home,无法核对 skill 是否装对了 codex 的技能目录"
grep -qF "$CH/skills" "$GEN" \
    && ok "生成器装的正是 deploy-codex.sh 里的 codex_home 落点($CH/skills)" \
    || fail "生成器的 codex 落点与 codex_home 对不上"
grep -qF '${HOME:-/root}' "$GEN" \
    && ok "生成器用 \${HOME:-/root},HOME 为空时不会写到 /" \
    || fail "生成器用裸 \$HOME,容器里 HOME 意外为空会写到文件系统根"
grep -qF '/workspace/cc-connect/data' "$SKILL" \
    && ok "skill 里的 data_dir 与 config.toml 一致" || fail "skill 里的 data_dir 对不上"
if grep -qF '50 MiB' "$SKILL"; then
    grep -qF 'DefaultMaxAttachmentSize int64 = 50 << 20' "$SRC/core/api.go" \
        && ok "50 MiB 上限与 core/api.go 一致" || fail "附件上限数字对不上源码"
else
    fail "skill 里没写附件大小上限 —— agent 遇到大文件会不知道为什么失败"
fi
echo

# ---------- 6. 把生成的安装命令真跑一遍 ----------
# 这一节才是本文件存在的理由:前面几节只能证明说明书"说得对",证明不了
# make-skill-cmd.sh 拼出来的命令"装得上"。三个落点少一个都是静默失败。
echo "══ 6. 安装命令在沙盒里真跑(三个落点都要落)══"
bash "$GEN" > "$VD/gen.out" 2>&1 || { fail "生成失败"; tail -3 "$VD/gen.out"; }
LINES="$(sed -n '/=== 下面这一整行就是命令/p' "$VD/gen.out" | wc -l | tr -d ' ')"
[ "$LINES" = "1" ] && ok "命令的标记行唯一" || fail "标记行出现 $LINES 次,取命令会取错"
CMD="$(sed -n '/=== 下面这一整行就是命令/{n;p;}' "$VD/gen.out")"
[ -n "$CMD" ] || { fail "没抠出命令体"; }

case "$CMD" in
    *'"'*|*"'"*) fail "命令体含引号 —— 过飞书会被换成弯引号" ;;
    *) ok "命令体不含引号(绕开飞书那道转换)" ;;
esac
if printf '%s' "$CMD" | LC_ALL=C grep -q '[^ -~]'; then
    fail "命令体含非 ASCII 字符"
else
    ok "命令体纯 ASCII(${#CMD} 字符)"
fi

# 两处容器内路径必须改写进沙盒,否则本机测试会写到项目外:
#   ① /tmp/...new  ② codex_home(如 /workspace/codex-home → MSYS 根下的 workspace/)
# 改写处数必须逐一对得上,少改一处就是往项目外写文件 —— 所以先断言再替换。
N1="$(printf '%s' "$CMD" | grep -oF '/tmp/feishu-send-SKILL.md.new' | wc -l | tr -d ' ')"
[ "$N1" = "5" ] && ok "/tmp 临时文件出现 5 处(解码 / 3 次 cp / 收尾删除)" \
    || fail "/tmp 路径出现 $N1 次(期望 5),命令改了测试就要跟着改"
N2="$(printf '%s' "$CMD" | grep -oF "$CH/skills" | wc -l | tr -d ' ')"
[ "$N2" = "3" ] && ok "codex_home 字面路径出现 3 处(mkdir / cp / md5sum)" \
    || fail "codex_home 字面路径出现 $N2 次(期望 3)"
if [ "$N1" != "5" ] || [ "$N2" != "3" ]; then
    fail "改写处数对不上;宁可不测,也不能让它在项目外造目录"
else
    CMD_SB="$(printf '%s' "$CMD" \
        | sed -e "s#/tmp/feishu-send-SKILL.md.new#$(w "$SB")/tmp/SKILL.md.new#g" \
              -e "s#$CH/skills#$SB/codexhome/skills#g")"
    printf '%s' "$CMD_SB" | grep -qF '/tmp/feishu-send-SKILL.md.new' \
        && fail "临时文件路径没改干净" || ok "临时文件已改写到沙盒"
    printf '%s' "$CMD_SB" | grep -qF "$CH" \
        && fail "codex 落点没改干净 —— 会写到项目外的 $CH" || ok "codex 落点已改写到沙盒"
fi

mkdir -p "$SB/tmp" "$SB/home" "$SB/codexhome"
MD5="$(md5sum "$SKILL" | cut -d' ' -f1)"

# 用 HOME/CODEX_HOME 指到沙盒 —— 命令里写的是 $HOME / $CODEX_HOME,
# 由 shell 展开,所以不需要 sed 改写路径,也就不存在"改漏一处写到真 HOME"的风险。
HOME="$SB/home" CODEX_HOME="$SB/codexhome" bash -c "$CMD_SB" > "$VD/run1.log" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "命令退出码 0" || { fail "命令退出码 $RC"; sed 's/^/     /' "$VD/run1.log"; }

for rel in ".claude/skills/feishu-send/SKILL.md" ".codex/skills/feishu-send/SKILL.md"; do
    if [ -f "$SB/home/$rel" ]; then
        [ "$(md5sum "$SB/home/$rel" | cut -d' ' -f1)" = "$MD5" ] \
            && ok "落点 \$HOME/$rel 内容正确" || fail "\$HOME/$rel 内容与源文件不一致"
    else
        fail "落点 \$HOME/$rel 没装上"
    fi
done
if [ -f "$SB/codexhome/skills/feishu-send/SKILL.md" ]; then
    [ "$(md5sum "$SB/codexhome/skills/feishu-send/SKILL.md" | cut -d' ' -f1)" = "$MD5" ] \
        && ok "落点 $CH/skills/... 内容正确" || fail "codex_home 那份内容不一致"
else
    fail "落点 $CH/skills/... 没装上 —— codex 实际读的就是这个"
fi

grep -qF "HOME=$SB/home" "$VD/run1.log" && ok "回显了 HOME(能看出装到了哪)" || fail "没回显 HOME"
[ "$(grep -c "^$MD5" "$VD/run1.log")" = "3" ] \
    && ok "回显了 3 行相同 md5,可直接和本地比" || fail "回显的 md5 行数不对"

# 再跑一次:必须覆盖而不是报错,也不许留下半截临时文件
HOME="$SB/home" CODEX_HOME="$SB/codexhome" bash -c "$CMD_SB" > "$VD/run2.log" 2>&1 \
    && ok "重复执行幂等(第二次仍退出 0)" || fail "第二次执行失败"
[ "$(grep -c "^$MD5" "$VD/run2.log")" = "3" ] && ok "第二次仍是 3 行相同 md5" || fail "第二次结果不对"
[ -f "$SB/tmp/SKILL.md.new" ] && fail "留下了半截临时文件" || ok "临时文件已清理"

# HOME 为空时 $HOME/.claude 会拼成 /.claude,写到文件系统根去。所以命令里用的是
# ${HOME:-/root},这里查两件事:默认值写法出现 6 次(mkdir 2 + cp 2 + md5sum 2),
# 以及那种裸写法的 $HOME/.claude 一处都没有。
[ "$(printf '%s' "$CMD" | grep -oF '${HOME:-/root}' | wc -l | tr -d ' ')" = "6" ] \
    && ok "\${HOME:-/root} 出现 6 次(mkdir×2/cp×2/md5sum×2),HOME 为空也不会写到 /" \
    || fail "\${HOME:-/root} 出现次数不对 —— 可能退回了裸 \$HOME"
[ "$(printf '%s' "$CMD" | grep -oF '$HOME/.claude' | wc -l | tr -d ' ')" = "0" ] \
    && ok "没有裸 \$HOME/.claude(HOME 为空时会写到文件系统根)" \
    || fail "命令里出现裸 \$HOME/.claude"
echo

echo "══ 结果 ══"
if [ "$FAIL" = "0" ]; then
    echo "✅ 全部断言通过"
    rm -rf "$VD"
    echo "   (沙盒已清理)"
else
    echo "❌ 存在失败断言"
    echo "   (沙盒保留在 $VD 供排查)"
    exit 1
fi
