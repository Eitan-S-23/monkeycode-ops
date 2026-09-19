#!/bin/bash
# 本地验证 deploy-codex.sh 第 2 步(Codex 冒烟测试)的取值与判定
#
# 为什么单独抽出来测:
#   冒烟测试是部署里唯一"向外发一次真实请求"的步骤,也是唯一会写 config.toml 的地方。
#   它跑在容器里、要等 180 秒、失败只留一段日志 —— 上游改错一个变量名,现场表现是
#   "冒烟测试未通过,provider 或模型名有问题",排查方向全指向网络,而真正的原因
#   可能是"冒烟线路压根没生效"。这里用假 codex 把这一步在本地跑穿。
#
# 做法:从 deploy-codex.sh 里**原样抽出**第 2 步那段脚本,只改写三处绝对路径
#   (SMOKE_HOME / cd / $NPM_BIN),再配一个假 codex 跑。改写处数必须对得上,
#   少改一处就会写到项目外或调用不存在的程序 —— 所以每处都先断言再替换。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/deploy-codex.sh"
VD="$HERE/.verify-smoke"
SB="$VD/sb"

rm -rf "$VD"
mkdir -p "$SB/bin" "$SB/seen"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

# ---------- 1. 抽出第 2 步 ----------
echo "══ 1. 从 deploy-codex.sh 抽出第 2 步 ══"
BLOCK="$VD/smoke-block.sh"
awk '/^# ---------- 2\. Codex 冒烟测试/{f=1}
     /^# ---------- 3\. 生成 config\.toml/{f=0}
     f' "$SRC" > "$BLOCK"
[ -s "$BLOCK" ] || { fail "没抽出任何内容 —— 脚本里第 2/3 步的分节注释改了?"; exit 1; }
grep -q 'SMOKE_MODEL=' "$BLOCK" && ok "抽出 $(wc -l < "$BLOCK" | tr -d ' ') 行(含 SMOKE_* 取值)" \
    || { fail "抽出的段落里没有 SMOKE_MODEL=,抽错地方了"; exit 1; }

# ---------- 2. 改写三处绝对路径 ----------
echo "══ 2. 把三处容器内路径改写到沙盒 ══"
n=0
for pat in 'SMOKE_HOME=/workspace/codex-home-smoke' 'cd /workspace ' '"\$NPM_BIN/codex"'; do
    c=$(grep -c -- "$pat" "$BLOCK")
    [ "$c" = "1" ] && n=$((n+1)) || fail "路径模式 $pat 命中 $c 次(应为 1 次)—— 脚本改了,测试要跟着改"
done
[ "$n" = "3" ] || { fail "只有 $n/3 处可安全改写;宁可不测,也不能让它在项目外造目录"; exit 1; }
sed -e "s#SMOKE_HOME=/workspace/codex-home-smoke#SMOKE_HOME=$SB/smokehome#" \
    -e "s#cd /workspace #cd $SB #" \
    -e "s#\"\$NPM_BIN/codex\"#\"$SB/bin/codex\"#" \
    "$BLOCK" > "$VD/smoke.sh"
grep -q "$SB/bin/codex" "$VD/smoke.sh" || { fail "改写没生效"; exit 1; }
grep -q '/workspace' "$VD/smoke.sh" && { fail "改写后仍残留 /workspace,会在项目外造目录"; exit 1; }
ok "三处已改写,且不再引用 /workspace"

# ---------- 3. 假 codex ----------
# 记录它看到的 config.toml / SMOKE_KEY,并按 FAKE_OUT 打印一段输出。
cat > "$SB/bin/codex" <<'STUB'
#!/bin/bash
cp "$CODEX_HOME/config.toml" "$SEEN_DIR/config.toml" 2>/dev/null
printf '%s' "${SMOKE_KEY:-}" > "$SEEN_DIR/key"
printf '%s\n' "$*" > "$SEEN_DIR/argv"
printf '%s\n' "$FAKE_OUT"
exit "${FAKE_RC:-0}"
STUB
chmod +x "$SB/bin/codex"

# 抽出来的段落只依赖这几个变量,给一套"主线路"基准值
export SEEN_DIR="$SB/seen"
export CODEX_BASE=https://main.example/v1
export CODEX_MODEL=gpt-5.6-sol
export CODEX_KEY=sk-main-key

# $1=场景名 $2=期望退出码(0/1) $3=FAKE_OUT
run_smoke() {
    local name="$1" want_rc="$2" out="$3"
    export FAKE_OUT="$out"
    rm -rf "$SB/smokehome"
    bash "$VD/smoke.sh" > "$VD/$name.log" 2>&1
    local rc=$?
    if [ "$rc" = "$want_rc" ]; then ok "$name: 退出码 $rc(符合预期)"
    else fail "$name: 退出码 $rc,期望 $want_rc"; sed 's/^/     /' "$VD/$name.log" | tail -6; fi
    return 0
}

# ---------- 4. 不指定冒烟线路:必须回退到主线路 ----------
echo "══ 3. 未给 CODEX_SMOKE_* 时回退到 CODEX_* ══"
unset CODEX_SMOKE_BASE CODEX_SMOKE_MODEL CODEX_SMOKE_KEY
run_smoke base-ok 0 "OK"
grep -q '^model = "gpt-5.6-sol"$' "$SEEN_DIR/config.toml" \
    && ok "config.toml 用的是 CODEX_MODEL" || fail "config.toml 的 model 不对: $(grep '^model' "$SEEN_DIR/config.toml")"
grep -q '^base_url = "https://main.example/v1"$' "$SEEN_DIR/config.toml" \
    && ok "config.toml 用的是 CODEX_BASE" || fail "config.toml 的 base_url 不对"
[ "$(cat "$SEEN_DIR/key")" = "sk-main-key" ] \
    && ok "codex 拿到的是 CODEX_KEY" || fail "codex 拿到的 key 不对"
grep -q '线路 https://main.example/v1 / 模型 gpt-5.6-sol' "$VD/base-ok.log" \
    && ok "开头打印了实际使用的线路与模型" || fail "没打印线路,出问题会不知道验的是哪条"
grep -q '来自 CODEX_SMOKE_' "$VD/base-ok.log" \
    && fail "回退场景不该出现「单独指定」的说明" || ok "没冒充「单独指定」"
[ -d "$SB/smokehome" ] && fail "通过后没清理临时 CODEX_HOME" || ok "通过后清理了临时 CODEX_HOME"
echo

# ---------- 5. 指定冒烟线路:三项都要换掉 ----------
echo "══ 4. 给了 CODEX_SMOKE_* 时走冒烟线路 ══"
export CODEX_SMOKE_BASE=https://smoke.example/v1
export CODEX_SMOKE_MODEL=deepseek-v4-flash
export CODEX_SMOKE_KEY=sk-smoke-key
run_smoke smoke-ok 0 "OK"
grep -q '^model = "deepseek-v4-flash"$' "$SEEN_DIR/config.toml" \
    && ok "config.toml 用的是 CODEX_SMOKE_MODEL" || fail "冒烟模型没生效: $(grep '^model' "$SEEN_DIR/config.toml")"
grep -q '^base_url = "https://smoke.example/v1"$' "$SEEN_DIR/config.toml" \
    && ok "config.toml 用的是 CODEX_SMOKE_BASE" || fail "冒烟 base_url 没生效"
[ "$(cat "$SEEN_DIR/key")" = "sk-smoke-key" ] \
    && ok "codex 拿到的是 CODEX_SMOKE_KEY" || fail "冒烟 key 没生效(拿到了别的 key)"
grep -q '线路 https://smoke.example/v1 / 模型 deepseek-v4-flash' "$VD/smoke-ok.log" \
    && ok "日志里能看出走的是冒烟线路" || fail "日志里看不出走的哪条线"
grep -q '来自 CODEX_SMOKE_' "$VD/smoke-ok.log" \
    && ok "标注了「单独指定」" || fail "没标注是单独指定,以后会误判成主线路"
echo

# ---------- 6. 只给其中一项:三项各自独立回退 ----------
echo "══ 5. 只给 CODEX_SMOKE_MODEL 时,地址与密钥仍取主线路 ══"
unset CODEX_SMOKE_BASE CODEX_SMOKE_KEY
run_smoke mixed 0 "OK"
grep -q '^model = "deepseek-v4-flash"$' "$SEEN_DIR/config.toml" \
    && ok "模型取自 CODEX_SMOKE_MODEL" || fail "模型没取到"
grep -q '^base_url = "https://main.example/v1"$' "$SEEN_DIR/config.toml" \
    && ok "地址回退到 CODEX_BASE" || fail "地址没回退"
[ "$(cat "$SEEN_DIR/key")" = "sk-main-key" ] \
    && ok "密钥回退到 CODEX_KEY" || fail "密钥没回退"
echo

# ---------- 7. 判定必须卡死 ----------
# 这一段是本文件存在的核心理由:旧判据 grep -qiE "OK|完成|success" 里,-i 让
# "broken pipe"的 bro**k**en 里的 ok 也算命中,provider 半路断流反而判通过。
# 新判据两层:① 必须出现**独立**的 ok(\b 词边界);② 不能出现接口层错误字样。
echo "══ 6. 判定:独立的 ok 才算,接口报错一律否决 ══"
unset CODEX_SMOKE_MODEL
run_smoke case-broken 1 "stream error: broken pipe"
grep -q '冒烟测试未通过' "$VD/case-broken.log" && ok "断流时判为未通过(旧判据这里会误判通过)" \
    || fail "断流没被判失败"
grep -q '模型名 gpt-5.6-sol' "$VD/case-broken.log" \
    && ok "报错里点名了实际验的模型" || fail "报错没点名模型"
[ -d "$SB/smokehome" ] && ok "失败时保留了临时 CODEX_HOME(可排查)" || fail "失败却清掉了排查材料"

# 中转站报错的原样回包 —— 里面没有独立的 ok,但要确认"有 error 字样就否决"生效
run_smoke case-api 1 '{"error":{"message":"Invalid token","type":"new_api_error"}}'
grep -q '冒烟测试未通过' "$VD/case-api.log" && ok "New API 错误回包判为未通过" || fail "错误回包判为通过"

# 最阴的一种:错误回包之外还夹着一个独立的 ok
run_smoke case-both 1 '{"error":{"message":"upstream load saturated"}} retry: ok'
grep -q '冒烟测试未通过' "$VD/case-both.log" \
    && ok "接口报错时,夹带的独立 ok 不能翻案" || fail "错误字样没被否决,冒烟会被骗过去"

run_smoke case-lower 0 "ok"
grep -q '冒烟测试通过' "$VD/case-lower.log" && ok "小写 ok 仍算过(大小写不敏感保留)" || fail "小写 ok 被误判为失败"

run_smoke case-empty 1 ""
grep -q '冒烟测试未通过' "$VD/case-empty.log" && ok "空输出判为未通过" || fail "空输出判为通过"

# codex 自己的告警行不能被误伤,否则运行期一条无关日志就能把好线路判死
run_smoke case-warn 0 "ERROR codex_core::config: failed to load user config
OK"
grep -q '冒烟测试通过' "$VD/case-warn.log" \
    && ok "codex 自己的 ERROR 日志行不致误判" || fail "把 codex 的普通告警当成接口错误了"

# 现场实录:codex 0.155 拒收 wire_api=chat。它既没有 OK,也不是网络问题 ——
# 提示必须指向"配置项与版本不兼容",否则下一次还会有人去查中转站。
run_smoke case-cfgschema 1 'Error loading config.toml: `wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"` in your provider config.
in `model_providers.smoke.wire_api`'
grep -q '冒烟测试未通过' "$VD/case-cfgschema.log" && ok "codex 配置项作废判为未通过" || fail "配置错误判为通过"
grep -q '配置项与 codex 版本不兼容' "$VD/case-cfgschema.log" \
    && ok "提示指向配置兼容性,而不是误导去查网络" || fail "提示仍指向密钥/网络/模型名"
grep -q 'wire_api = "responses"' "$VD/smoke.sh" \
    && ok "冒烟配置用的是 wire_api = responses" || fail "冒烟配置没跟上 codex 版本要求"
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
