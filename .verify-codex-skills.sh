#!/bin/bash
# 本地验证:codex 本体到底认不认我们装的 skill
#
# 为什么必须有这一条:
#   前面 .verify-skill.sh 只能证明"文件装到了那个目录",证明不了"codex 会读"。
#   而这件事**没法靠读文档确定** —— cc-connect 源码里 codexSkillDirs() 把
#   $HOME/.claude/skills 也列了进去(注释还写着 "Codex deliberately shares
#   Claude-format SKILL.md directories"),看着像"装一份就够";但 codex 二进制里
#   只有 CODEX_HOME/skills、/.codex/skills、./skills/,没有 .claude/skills。
#   两边打架时,唯一可信的是**让 codex 自己说**:
#
#       codex debug prompt-input  → 把模型实际看到的内容渲染成 JSON
#
#   它不调模型、不花 token、不需要登录,是本机就能跑的决定性判据。
#
# 已验证的结论(2026-09-20,本机 codex-cli 0.153.4):
#   ✅ <CODEX_HOME>/skills/<名>/SKILL.md 会被读到(命中);挪走就命中 0
#   ✅ 目录名与 frontmatter 的 name 不一致**也认**(但不依赖这条,仍保持一致)
#   ⚠️ $HOME/.codex/skills 与 $HOME/.claude/skills 在本机**测不出来**:
#      Windows 上 codex 用系统 API 解析家目录,不认 HOME/USERPROFILE 覆盖,
#      改了两者后连正对照都会失效 —— 属于无效对照,不是"不支持"的结论。
#      所以容器里只认准 $CODEX_HOME/skills 这一条;另外两份副本是低成本保险,
#      不指望它们兜底。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/skills/feishu-send/SKILL.md"
SB="$HERE/.verify-codex-skills/sb"
CODEX="${CODEX:-$(command -v codex || echo /c/Users/SU/AppData/Roaming/npm/codex)}"
# 被验的 skill 名,取自目录名 —— 与 frontmatter 的 name 一致(第 1 节已断言)
NAME="feishu-send"

rm -rf "$HERE/.verify-codex-skills"; mkdir -p "$SB"
M() { cygpath -m "$1"; }

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

[ -f "$SRC" ] || { echo "❌ 找不到 $SRC"; exit 1; }
[ -x "$CODEX" ] || { echo "⚠️  本机没有 codex,跳过本节(codex 技能发现无法验证)"; exit 0; }

# 命中数:codex 渲染出的模型可见内容里出现几次 skill 名
hits() { (cd "$SB" && env "$1" "$CODEX" debug prompt-input "hi" 2>/dev/null | grep -c "$NAME"); }

echo "══ 1. codex 版本 ══"
V="$("$CODEX" --version 2>&1 | head -1)"
echo "  $V"
echo "  (容器里是既有安装,部署脚本只检查存在不装,版本可能与本机不同 ——"
echo "   版本差异会影响 skill 是否受支持,这是本项验证覆盖不到的地方)"
echo

echo "══ 2. 正对照:<CODEX_HOME>/skills 放了 skill ══"
mkdir -p "$SB/codexhome/skills/$NAME"
cp "$SRC" "$SB/codexhome/skills/$NAME/SKILL.md"
H1="$(hits "CODEX_HOME=$(M "$SB/codexhome")")"
[ "$H1" -ge 1 ] && ok "codex 读到了($H1 处命中)" \
    || fail "codex 没读到 —— 落点或 frontmatter 格式有问题,skill 装了也白装"
echo

echo "══ 3. 负对照:把 skill 挪走,必须不再命中 ══"
mv "$SB/codexhome/skills/$NAME" "$SB/_moved"
H2="$(hits "CODEX_HOME=$(M "$SB/codexhome")")"
[ "$H2" = "0" ] && ok "挪走后命中 0 —— 证明第 2 节的命中确实来自这个文件" \
    || fail "挪走后仍命中 $H2 处,说明命中的是别的东西,实验不成立"
mv "$SB/_moved" "$SB/codexhome/skills/$NAME"
echo

echo "══ 4. frontmatter 是 codex 认的格式吗(它读到的是 name/description) ══"
OUT="$SB/prompt.json"
(cd "$SB" && CODEX_HOME="$(M "$SB/codexhome")" "$CODEX" debug prompt-input "hi" > "$OUT" 2>/dev/null)
grep -q "feishu-send" "$OUT" && ok "skill 出现在模型可见内容里" || fail "没出现"
# 本文件最硬的一条证据:codex 自己吐出来的技能说明里就写着 $CODEX_HOME/skills。
# 它不是我的推断,是 codex 的原话 —— 上头,比任何源码注释都可靠。
if grep -qF '$CODEX_HOME/skills' "$OUT"; then
    ok "codex 自己的说明里写着 \$CODEX_HOME/skills(落点得到本体确认)"
else
    fail "codex 的说明里没提 \$CODEX_HOME/skills —— 版本可能变了,落点要重新确认"
fi
# 抽一段上下文,确认它是以"技能清单"的形式出现,而不是被当成普通文本
PYTHONIOENCODING=utf-8 python - "$(M "$OUT")" "$NAME" <<'PYEOF'
import pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
name = sys.argv[2]
i = raw.find(f"skills/{name}")
if i < 0:
    i = raw.find(name)
snippet = raw[max(0, i - 300):i + 200].replace("\\n", "\n")
print("  它读到的样子(name 后面的就是 frontmatter 的 description):")
for line in snippet.splitlines()[-6:]:
    print("    " + line.strip()[:160])
PYEOF
echo

echo "══ 结果 ══"
if [ "$FAIL" = "0" ]; then
    echo "✅ codex 确实会扫 <CODEX_HOME>/skills,落点成立"
    rm -rf "$HERE/.verify-codex-skills"
    echo "   (沙盒已清理)"
else
    echo "❌ 存在失败断言;沙盒保留在 $SB 供排查"
    exit 1
fi
