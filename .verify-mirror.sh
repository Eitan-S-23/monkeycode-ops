#!/bin/bash
# 本地验证"把本机 provider 搬进容器"这条链路
#
# 分两段,因为两段的数据敏感度不同:
#   A. 导出(export-local-providers.py)—— 用真实的本机配置跑,产物含真实密钥,
#      所以校验完立刻删除,不留档。
#   B. 合并(apply-providers.py)—— 用假密钥的合成片段跑,产物可以留在沙盒里排查。
#
# 不连容器。沙盒配置由 deploy-codex.sh 里那段生成器原样产出,保证结构一致。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VD="$HERE/.verify-mirror"
SB="$VD/sb"
PY="${PY:-python}"

# Windows 上 python 默认按 GBK 编码 stdout,打印 ✅ 会抛 UnicodeEncodeError
export PYTHONUTF8=1

rm -rf "$VD"
mkdir -p "$SB/cc-connect/data/sessions"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

CFG="$SB/cc-connect/config.toml"

# ---------- 1. 静态检查 ----------
echo "══ 1. 脚本静态检查 ══"
for f in export-local-providers.py apply-providers.py; do
    "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$HERE/$f" \
        && ok "$f 语法通过" || fail "$f 语法错误"
done
echo

# ---------- 2. 用真实生成器造一份沙盒 config.toml ----------
echo "══ 2. 生成沙盒 config.toml(与容器同构) ══"
GEN="$VD/gen.py"
awk '/python3 - <<.PYEOF./{f=1;next} /^PYEOF[[:space:]]*$/{f=0} f' "$HERE/deploy-codex.sh" > "$GEN"
[ -s "$GEN" ] || { echo "❌ 没能抽出生成器"; exit 1; }
"$PY" - "$GEN" "$CFG" "$SB/feishu-bot/feishu-bot-config.json" <<'PATCH'
import pathlib, sys
gen, cfg, bot = sys.argv[1], sys.argv[2], sys.argv[3]
t = pathlib.Path(gen).read_text(encoding="utf-8")
t = t.replace('pathlib.Path("/workspace/cc-connect/config.toml")', f'pathlib.Path({cfg!r})')
t = t.replace('pathlib.Path("/workspace/feishu-bot/feishu-bot-config.json")', f'pathlib.Path({bot!r})')
pathlib.Path(gen).write_text(t, encoding="utf-8")
PATCH
MODE=new CODEX_KEY=sk-old-codex CODEX_MODEL=old-model CODEX_BASE=https://old.example/v1 \
CODEX_PROVIDER_NAME=main CODEX_MODELS='old-model:old' \
CLAUDE_FEISHU_APP_ID=cli_fakeclaude001 CLAUDE_FEISHU_APP_SECRET=fakesecret \
CLAUDE_KEY=sk-old-claude CLAUDE_MODEL=old-claude CLAUDE_BASE=https://old.example/anthropic \
CLAUDE_PROVIDER_NAME=main CLAUDE_MODELS='old-claude:oldc' WANT_CLAUDE=1 \
CODEX_FEISHU_APP_ID=cli_fakecodex001 CODEX_FEISHU_APP_SECRET=fakesecret \
"$PY" "$GEN" > "$VD/gen.out" 2>&1 || { echo "❌ 生成失败"; tail -5 "$VD/gen.out"; exit 1; }
ok "沙盒配置已生成(旧的单 provider: main)"
echo

# ---------- 3. A 段:导出(真实数据,校验完即删) ----------
echo "══ 3. 从真实本机配置导出(应当只有 1 个文件) ══"
REAL_OUT="$VD/real"
"$PY" "$HERE/export-local-providers.py" --out-dir "$REAL_OUT" > "$VD/export.out" 2>&1
RC=$?
sed 's/^/  /' "$VD/export.out"
[ "$RC" = "0" ] || fail "导出脚本退出码 $RC"

BUNDLE="$REAL_OUT/providers.toml"
[ -f "$BUNDLE" ] && ok "产出单个 providers.toml" || fail "没生成 providers.toml"
N_FILES=$(find "$REAL_OUT" -type f | wc -l | tr -d ' ')
[ "$N_FILES" = "1" ] && ok "输出目录里只有 1 个文件" || fail "输出目录里有 $N_FILES 个文件,应当只有 1 个"

if [ "$RC" = "0" ] && [ -f "$BUNDLE" ]; then
"$PY" - "$BUNDLE" <<'PYEOF'
import pathlib, re, sys, tomllib

# 这里刻意不复用 apply-providers.py 的 parse_bundle —— 测试若和被测代码共用
# 同一套解析,解析写错了会两边一起错、照样"通过"。独立实现一份最简解析。
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
secs, cur = {}, None
for ln in text.splitlines():
    s = ln.strip()
    m = re.match(r"^#\s*@project\s+(\S+)\s*$", s)
    if m:
        cur = m.group(1)
        if cur in secs:
            print(f"  ❌ {cur} 段重复"); sys.exit(1)
        secs[cur] = {"default": "", "lines": []}
        continue
    m = re.match(r"^#\s*@default-provider\s+(\S+)\s*$", s)
    if m:
        if cur is None:
            print("  ❌ @default-provider 在任何 @project 之前"); sys.exit(1)
        secs[cur]["default"] = m.group(1)
        continue
    if s.startswith("#"):
        continue
    if cur is None:
        if s:
            print(f"  ❌ 有内容不属于任何段: {s[:50]!r}"); sys.exit(1)
        continue
    secs[cur]["lines"].append(ln)

if set(secs) != {"codex", "claude"}:
    print(f"  ❌ 分段名不对: {sorted(secs)}"); sys.exit(1)

src = tomllib.loads((pathlib.Path.home()/".cc-connect"/"config.toml").read_text(encoding="utf-8"))
bad = []
for kind, proj in (("codex", "codex-test2"), ("claude", "claude-test2")):
    body = "\n".join(secs[kind]["lines"]).strip("\n")
    doc = tomllib.loads('[[projects]]\nname = "x"\n  [projects.agent]\n    type = "t"\n' + body)
    got = doc["projects"][0]["agent"]["providers"]
    want = next(p for p in src["projects"] if p["name"] == proj)["agent"]["providers"]
    want = [p for p in want if str(p.get("base_url","")).startswith("http") and (p.get("api_key") or "").strip()]
    wmap = {p["name"]: p for p in want}
    if len(got) != len(want):
        bad.append(f"{kind} provider 数 {len(got)} != {len(want)}")
    for g in got:
        w = wmap.get(g["name"])
        if not w:
            bad.append(f"{kind} 多出 {g['name']}"); continue
        for k in ("api_key", "base_url", "model"):
            if g.get(k) != w.get(k):
                bad.append(f"{kind}: {g['name']}.{k} 不一致")   # 不回显值
        if [(m["model"], m.get("alias")) for m in g.get("models") or []] != \
           [(m["model"], m.get("alias")) for m in w.get("models") or []]:
            bad.append(f"{kind}: {g['name']} 别名不一致")
        if (g.get("env") or {}) != (w.get("env") or {}):
            bad.append(f"{kind}: {g['name']}.env 不一致")
    # 默认 provider 必须跟着走,否则合并后会指向一个已被删掉的 provider
    want_def = next(p for p in src["projects"] if p["name"] == proj)["agent"]["options"].get("provider")
    if secs[kind]["default"] != want_def:
        bad.append(f"{kind} 默认 provider {secs[kind]['default']!r} != 本机 {want_def!r}")
    if "work_dir" in body or "http_proxy" in body:
        bad.append(f"{kind} 带上了与本机绑定的路径/代理键")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ 单文件里两段内容都与本机逐字段一致,且未带 work_dir/代理")
PYEOF
[ $? = 0 ] || FAIL=1
fi

# 产物含真实密钥,无论成败立即删除
rm -rf "$REAL_OUT"
[ -d "$REAL_OUT" ] && fail "真实密钥产物没删掉" || ok "真实密钥产物已清理"
echo

# ---------- 4. B 段:合并(假密钥) ----------
echo "══ 4. 合并进沙盒配置 ══"
FRAG="$VD/frag"
mkdir -p "$FRAG"
cat > "$FRAG/providers.toml" <<'EOF'
# 测试用片段(假密钥)
#   codex  ← 本机 codex-x
#   claude ← 本机 claude-x

# @project codex
# @default-provider alpha
  [[projects.agent.providers]]
    name = "alpha"
    api_key = "sk-fake-alpha"
    base_url = "https://alpha.example/v1"
    model = "gpt-5.6-sol"
    [[projects.agent.providers.models]]
      model = "gpt-5.6-sol"
      alias = "sol"
    [[projects.agent.providers.models]]
      model = "gpt-5.5"
      alias = "g5"

  [[projects.agent.providers]]
    name = "beta"
    api_key = "sk-fake-beta"
    base_url = "https://beta.example/v1"
    model = "gpt-5.4"

# @project claude
# @default-provider gamma
  [[projects.agent.providers]]
    name = "gamma"
    api_key = "sk-fake-gamma"
    base_url = "https://gamma.example"
    model = "claude-opus-5[1M]"
    [[projects.agent.providers.models]]
      model = "claude-opus-5[1M]"
      alias = "opus"
    [projects.agent.providers.env]
      ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-5[1M]"
      autoDreamEnabled = "true"
EOF
"$PY" "$HERE/apply-providers.py" --config "$CFG" "$FRAG/providers.toml" > "$VD/apply.out" 2>&1
RC=$?
sed 's/^/  /' "$VD/apply.out"
[ "$RC" = "0" ] || fail "合并脚本退出码 $RC"
echo

# ---------- 5. 回验合并结果 ----------
echo "══ 5. 回验合并结果 ══"
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
doc = tomllib.loads(raw)
projs = {p["name"]: p for p in doc["projects"]}
bad = []
def want(c, m):
    if not c: bad.append(m)

want(set(projs) == {"codex", "claude"}, f"project 集合变了: {set(projs)}")

cx = projs["codex"]["agent"]
want([p["name"] for p in cx["providers"]] == ["alpha", "beta"],
     f"codex provider 不对: {[p['name'] for p in cx['providers']]}")
want(cx["options"]["provider"] == "alpha", f"codex 默认 provider 未更新: {cx['options']['provider']}")
want([m.get("alias") for m in cx["providers"][0]["models"]] == ["sol", "g5"], "codex 别名不对")
# 旧 provider 必须清干净,否则 /model 里会留一个指向旧中转站的僵尸项
want(not any(p["name"] == "main" for p in cx["providers"]), "旧的 main provider 没被替换掉")

cl = projs["claude"]["agent"]
want([p["name"] for p in cl["providers"]] == ["gamma"], "claude provider 不对")
want(cl["options"]["provider"] == "gamma", "claude 默认 provider 未更新")
want(cl["providers"][0]["env"].get("autoDreamEnabled") == "true", "claude 的 env 子表丢了")
want(cl["providers"][0]["model"] == "claude-opus-5[1M]", "claude 模型名里的 [1M] 被转义弄坏了")

# 最危险的失败模式:替换 provider 段时把后面的 platforms 段一起吃掉
for name in ("codex", "claude"):
    plats = projs[name].get("platforms") or []
    if not plats:
        bad.append(f"{name} 的 platforms 段被吃掉了")
        continue
    opts = plats[0].get("options") or {}
    if not str(opts.get("app_id", "")).startswith("cli_"):
        bad.append(f"{name} 的 platforms.options.app_id 丢了: {opts}")
# agent.options 里非 provider 的键必须原样保留
want(projs["codex"]["agent"]["options"].get("sandbox_mode") == "workspace-write",
     "codex 的 sandbox_mode 丢了")
want(projs["codex"]["agent"]["options"].get("codex_home") == "/workspace/codex-home",
     "codex 的 codex_home 丢了")
want(projs["claude"]["agent"]["options"].get("work_dir") == "/workspace",
     "claude 的 work_dir 丢了")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ provider/默认项/别名/env 全对,platforms 与其余 options 未被波及")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 6. 幂等:再跑一次结果不变 ----------
echo "══ 6. 再跑一次必须幂等(不堆叠) ══"
cp "$CFG" "$VD/after-first.toml"
"$PY" "$HERE/apply-providers.py" --config "$CFG" "$FRAG/providers.toml" > "$VD/apply2.out" 2>&1
if diff -q "$VD/after-first.toml" "$CFG" >/dev/null; then
    ok "两次结果完全一致"
else
    fail "第二次跑出了不同的内容"; diff "$VD/after-first.toml" "$CFG" | head -10
fi
N=$(grep -c '^[[:space:]]*\[\[projects\.agent\.providers\]\]$' "$CFG")
[ "$N" = "3" ] && ok "provider 段共 3 个(2 codex + 1 claude),未堆叠" || fail "provider 段数量异常: $N"
echo

# ---------- 7. 坏片段必须被拦下 ----------
echo "══ 7. 坏片段拦截 ══"
mkbad() {   # $1=文件名 $2=内容
    { printf '# 测试用坏片段\n\n# @project codex\n'; printf '%s\n' "$2"; } > "$VD/$1"
}
mkbad "bad-dup.toml" '# @default-provider x
  [[projects.agent.providers]]
    name = "x"
    api_key = "k"
    base_url = "https://x.example"
  [[projects.agent.providers]]
    name = "x"
    api_key = "k2"
    base_url = "https://x.example"'
"$PY" "$HERE/apply-providers.py" --config "$CFG" --only codex "$VD/bad-dup.toml" > "$VD/dup.out" 2>&1
[ $? != 0 ] && ok "同名 provider 被拒绝: $(grep '重复' "$VD/dup.out" | head -1)" || fail "同名 provider 没被拦下"

mkbad "bad-url.toml" '# @default-provider y
  [[projects.agent.providers]]
    name = "y"
    api_key = "k"
    base_url = "1"'
"$PY" "$HERE/apply-providers.py" --config "$CFG" --only codex "$VD/bad-url.toml" > "$VD/url.out" 2>&1
[ $? != 0 ] && ok "非法 base_url 被拒绝" || fail "非法 base_url 没被拦下"

mkbad "bad-def.toml" '# @default-provider 不在列表里
  [[projects.agent.providers]]
    name = "z"
    api_key = "k"
    base_url = "https://z.example"'
"$PY" "$HERE/apply-providers.py" --config "$CFG" --only codex "$VD/bad-def.toml" > "$VD/def.out" 2>&1
[ $? != 0 ] && ok "默认 provider 不在列表里被拒绝" || fail "悬空的默认 provider 没被拦下"

# 文件被手工改坏(有内容跑到 @project 之前)也必须拦下,而不是静默丢掉
printf '  [[projects.agent.providers]]\n    name = "orphan"\n\n# @project codex\n# @default-provider alpha\n  [[projects.agent.providers]]\n    name = "alpha"\n    api_key = "k"\n    base_url = "https://a.example"\n' > "$VD/bad-orphan.toml"
"$PY" "$HERE/apply-providers.py" --config "$CFG" --only codex "$VD/bad-orphan.toml" > "$VD/orphan.out" 2>&1
[ $? != 0 ] && ok "不属于任何段的内容被拒绝" || fail "游离内容没被拦下"

# --only 写错 project 名要给出可用列表,而不是只说"没有可执行的合并"
"$PY" "$HERE/apply-providers.py" --config "$CFG" --only codexx "$FRAG/providers.toml" > "$VD/only.out" 2>&1
[ $? != 0 ] && grep -q 'codex, claude' "$VD/only.out" \
    && ok "--only 写错时列出了可用 project" || fail "--only 报错信息没列出可用 project"

# 上面几次都该在落盘前失败,配置不能被改动
diff -q "$VD/after-first.toml" "$CFG" >/dev/null && ok "五次失败都没有动过配置" || fail "失败路径竟然写了盘"
echo

# ---------- 8. 非 UTF-8 输出环境 ----------
echo "══ 8. 非 UTF-8 输出环境下仍要正常收尾 ══"
env -u PYTHONUTF8 -u PYTHONIOENCODING "$PY" "$HERE/apply-providers.py" --config "$CFG" --only codex \
    "$FRAG/providers.toml" > "$VD/enc.out" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "无 PYTHONUTF8 时仍以 0 退出" || { fail "退出码 $RC(编码问题会把成功误判为失败)"; tail -5 "$VD/enc.out"; }
echo

# ---------- 9. 沙盒外没有写入 ----------
echo "══ 9. 沙盒之外没有写入 ══"
[ -d "$VD" ] && ok "所有产物都在 $VD 内" || fail "沙盒目录异常"
echo

echo "══ 结果 ══"
if [ "$FAIL" = "0" ]; then
    echo "✅ 全部断言通过"
    rm -rf "$VD"
    echo "   (沙盒已清理)"
else
    echo "❌ 存在失败断言"
    echo "   (沙盒保留在 $VD 供排查;里面只有假密钥)"
    exit 1
fi
