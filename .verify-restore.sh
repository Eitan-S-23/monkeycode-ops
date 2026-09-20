#!/bin/bash
# 本地验证 restore-all.sh:用桩 pgrep/flock/curl + 沙盒目录树跑三个场景
#
# 做法与既有的 .verify-provider-name.py 一致:不真连容器,只把脚本里的
# /workspace 前缀替换成沙盒路径,再用桩控制"哪些进程在跑",断言每个服务的
# 拉起/跳过决策正确。
#
# 桩的语义:
#   pgrep  —— 只认 $VERIFY_RUNNING 里登记的进程行(每行一条完整命令行)
#   flock  —— 忽略锁直接跑命令,但套 timeout 6,避免 watchdog 无限循环留残留
#   curl   —— 由 $VERIFY_CPA_UP 决定 CPA 端口通不通

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/restore-all.sh"
VD="$HERE/.verify-restore"
SB="$VD/sb"
BIN="$VD/bin"

[ -f "$SRC" ] || { echo "❌ 找不到 $SRC"; exit 1; }

# 上次残留的 watchdog 循环可能还占着目录,先让它看到 .stop 自行退出
for d in "$SB"/workspace/*/; do [ -d "$d" ] && touch "$d/.stop" 2>/dev/null; done
sleep 1
rm -rf "$VD"
mkdir -p "$BIN" "$SB/workspace"

# ---------- 桩 pgrep ----------
cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
# 桩 pgrep:在 $VERIFY_RUNNING 里找进程。每行是一条完整命令行。
mode=""; pattern=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x) mode=x; shift ;;
        -f) mode=f; shift ;;
        -*) shift ;;
        *) pattern="$1"; shift ;;
    esac
done
[ -f "${VERIFY_RUNNING:-/nonexistent}" ] || exit 1
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$mode" = x ]; then
        # -x:比较可执行文件名(comm),模拟 /proc 里的截断行为
        cmd="${line%% *}"
        [ "$(basename "$cmd")" = "$pattern" ] && { echo "$line"; exit 0; }
    else
        # -f:正则匹配整条命令行;^ 由调用方自己加
        printf '%s' "$line" | grep -qE "$pattern" && { echo "$line"; exit 0; }
    fi
done < "$VERIFY_RUNNING"
exit 1
EOF

# ---------- 桩 flock ----------
cat > "$BIN/flock" <<'EOF'
#!/bin/bash
# 桩 flock:忽略 -n 与锁文件,直接跑命令;套 timeout 防空转残留
shift 2
exec timeout 6 "$@"
EOF

# ---------- 桩 curl ----------
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
# 桩 curl:只用来探 CPA 端口,$VERIFY_CPA_UP=1 表示端口通
[ "${VERIFY_CPA_UP:-0}" = "1" ] && exit 0
exit 7
EOF

chmod +x "$BIN/pgrep" "$BIN/flock" "$BIN/curl"

# ---------- 沙盒目录树(每次场景前重建) ----------
build_sandbox() {
    rm -rf "$SB/workspace"
    mkdir -p "$SB/workspace/cc-connect" "$SB/workspace/feishu-bot" \
             "$SB/workspace/cpa" "$SB/workspace/cloudflared-state" \
             "$SB/workspace/clash"

    cat > "$SB/workspace/cc-connect/run.sh" <<EOF
#!/bin/bash
# 桩启动器:登记自己进进程表再长睡,模拟真进程
echo "$SB/workspace/cc-connect/cc-connect --config $SB/workspace/cc-connect/config.toml" >> "\$VERIFY_RUNNING"
sleep 30
EOF

    # CPA 的 argv[0] 刻意写成相对路径 —— 复现容器里的真实形态(实测 ps 输出为
    # "./cli-proxy-api --config config.yaml"),用来验证"判活必须按进程名而不是
    # ^绝对路径"这条:写成绝对路径的判活会在真容器里永远判成"没在跑"。
    cat > "$SB/workspace/cpa/run.sh" <<EOF
#!/bin/bash
cd "$SB/workspace/cpa"
echo "./cli-proxy-api --config config.yaml" >> "\$VERIFY_RUNNING"
sleep 30
EOF
    chmod +x "$SB/workspace/cpa/run.sh" "$SB/workspace/cc-connect/run.sh"

    cat > "$SB/workspace/feishu-bot/install.sh" <<EOF
#!/bin/bash
# 桩安装脚本:登记 bot 进程
echo "$SB/workspace/feishu-bot/venv/bin/python $SB/workspace/feishu-bot/feishu-bot.py" >> "\$VERIFY_RUNNING"
EOF
    chmod +x "$SB/workspace/feishu-bot/install.sh"

    cat > "$SB/workspace/cc-connect/deploy-cpa-tunnel.sh" <<EOF
#!/bin/bash
echo launched > "$SB/workspace/cloudflared-state/launched.marker"
EOF
    chmod +x "$SB/workspace/cc-connect/deploy-cpa-tunnel.sh"

    # Clash:restore-all.sh 只"调"安装脚本,拉起动作在脚本里 —— 桩照这个分工写,
    # mihomo 的进程登记由桩 clash-install.sh 完成(与容器里的真实行为一致)。
    # 留 marker 是为了能断言"该跳过时确实没调脚本",光看进程表分不清是没调还是调了没起来。
    printf 'port: 7890\nsocks-port: 7891\n' > "$SB/workspace/clash/config.yaml"
    cat > "$SB/workspace/cc-connect/clash-install.sh" <<EOF
#!/bin/bash
touch "$SB/workspace/clash/installed.marker"
echo "$SB/workspace/clash/mihomo -d $SB/workspace/clash" >> "\$VERIFY_RUNNING"
EOF
    chmod +x "$SB/workspace/cc-connect/clash-install.sh"

    : > "$SB/workspace/cc-connect/config.toml"
    : > "$SB/workspace/feishu-bot/feishu-bot-config.json"
}

# ---------- 把脚本的 /workspace 前缀换成沙盒路径 ----------
sed "s#/workspace/#$SB/workspace/#g" "$SRC" > "$VD/restore-sandbox.sh"
chmod +x "$VD/restore-sandbox.sh"
# 检查有没有漏替换的 /workspace/(已被替换的都会带上 $SB 前缀,故排除含该前缀的行)
LEFTOVER=$(grep -n '/workspace/' "$VD/restore-sandbox.sh" | grep -v "$SB/workspace/")
if [ -n "$LEFTOVER" ]; then
    echo "❌ 路径替换不完整:"; echo "$LEFTOVER" | head; exit 1
fi

FAIL=0
OUT="$VD/out.txt"

# $1=场景名 $2=预置进程表 $3=CPA端口通否 $4=bot的app_id $5=cc的app_id
run_case() {
    local name="$1" running="$2" cpaup="$3" botid="$4" ccid="$5"
    build_sandbox
    : > "$VD/running"
    if [ -n "$running" ]; then printf '%s\n' "$running" >> "$VD/running"; fi
    [ -n "$botid" ] && printf '{"app_id":"%s"}\n' "$botid" > "$SB/workspace/feishu-bot/feishu-bot-config.json"
    [ -n "$ccid" ] && printf 'app_id = "%s"\n' "$ccid" > "$SB/workspace/cc-connect/config.toml"

    echo "══ 场景:$name ══"
    VERIFY_RUNNING="$VD/running" VERIFY_CPA_UP="$cpaup" PATH="$BIN:$PATH" \
        timeout 200 bash "$VD/restore-sandbox.sh" > "$OUT" 2>&1
    local rc=$?

    echo "  --- 关键判定 ---"
    grep -E "部署模式|➖|✅|⚠️|❌" "$OUT" | sed 's/^/  /'
    echo "  --- 场景结束时的进程表 ---"
    sort -u "$VD/running" | sed 's/^/    /'
    echo "  (脚本退出码 $rc)"
    echo
}

fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

# 场景 A:全新重启,什么都没跑;新建机器人模式(app_id 不同)
run_case "A 全新重启(新建机器人模式)" "" "0" "cli_botappid01" "cli_codexappid02"
cp "$OUT" "$VD/outA.txt"
grep -q "部署模式:新建机器人模式" "$VD/outA.txt" && ok "A: 识别为新建机器人模式" || fail "A: 模式识别错误"
grep -q "cli-proxy-api --config config.yaml" "$VD/running" && ok "A: CPA 被拉起" || fail "A: CPA 未拉起"
grep -q "cc-connect --config" "$VD/running" && ok "A: cc-connect 被拉起" || fail "A: cc-connect 未拉起"
grep -q "feishu-bot.py" "$VD/running" && ok "A: 自研 bot 被拉起" || fail "A: 自研 bot 未拉起"
[ -f "$SB/workspace/cloudflared-state/launched.marker" ] && ok "A: 隧道脚本被调用" || fail "A: 隧道脚本未调用"
[ -f "$SB/workspace/clash/installed.marker" ] && ok "A: clash 安装脚本被调用" || fail "A: clash 安装脚本未调用"
grep -q "clash/mihomo" "$VD/running" && ok "A: mihomo 被拉起" || fail "A: mihomo 未拉起"
echo

# 场景 B:所有服务都在跑 —— 应当全部跳过,进程表不应新增
run_case "B 全在跑(应全跳过)" \
"$SB/workspace/cpa/cli-proxy-api --config config.yaml
$SB/workspace/cc-connect/cc-connect --config $SB/workspace/cc-connect/config.toml
$SB/workspace/feishu-bot/venv/bin/python $SB/workspace/feishu-bot/feishu-bot.py
cloudflared tunnel --no-autoupdate run --token xxx
$SB/workspace/clash/mihomo -d $SB/workspace/clash" \
    "1" "cli_botappid01" "cli_codexappid02"
cp "$OUT" "$VD/outB.txt"
SKIP=$(grep -c "➖ 已在运行" "$VD/outB.txt")
[ "$SKIP" -ge 5 ] && ok "B: 五个服务全部识别为已在运行(命中 $SKIP 处)" || fail "B: 只识别出 $SKIP 处已在运行,期望 ≥5"
[ -f "$SB/workspace/cloudflared-state/launched.marker" ] && fail "B: 隧道脚本被重复调用" || ok "B: 未重启隧道"
[ -f "$SB/workspace/clash/installed.marker" ] && fail "B: clash 安装脚本被重复调用" || ok "B: 未重跑 clash 安装脚本"
grep -c "clash/mihomo" "$VD/running" | grep -qx 1 && ok "B: 没有起出第二份 mihomo" || fail "B: mihomo 进程条目不止一条(起了第二份)"
[ -f "$SB/workspace/cc-connect/run.sh" ] && ok "B: 未重写 cc-connect 启动器" || fail "B: 启动器被覆盖"
echo

# 场景 C:复用模式 —— cc-connect 占的就是 bot 的 App,不得拉起 bot
run_case "C 复用模式(不应拉 bot)" "cloudflared tunnel run" "1" "cli_sameapp123" "cli_sameapp123"
cp "$OUT" "$VD/outC.txt"
grep -q "部署模式:复用模式" "$VD/outC.txt" && ok "C: 识别为复用模式" || fail "C: 模式识别错误"
grep -q "复用模式下它与 cc-connect 抢同一个 App" "$VD/outC.txt" && ok "C: 明确说明不拉 bot 的原因" || fail "C: 未给出跳过说明"
grep -q "feishu-bot.py" "$VD/running" && fail "C: 复用模式下仍拉起了 bot(会抢长连接)" || ok "C: 确实没有拉起 bot"
echo

# 场景 D:cloudflared 的 watchdog 命令行含 "cloudflared-state/tunnel.log",
# 旧的裸 -f 判活会把它误认成隧道进程 —— 这里确保新判活不再踩这个坑
build_sandbox
: > "$VD/running"
echo "bash -c while true; do bash $SB/workspace/cloudflared-state/run.sh >> $SB/workspace/cloudflared-state/tunnel.log 2>&1; sleep 10; done" >> "$VD/running"
printf 'app_id = "cli_a1"\n' > "$SB/workspace/cc-connect/config.toml"
printf '{"app_id":"cli_b2"}\n' > "$SB/workspace/feishu-bot/feishu-bot-config.json"
echo "══ 场景:D watchdog 命令行不得被误判为隧道进程 ══"
VERIFY_RUNNING="$VD/running" VERIFY_CPA_UP="1" PATH="$BIN:$PATH" \
    timeout 200 bash "$VD/restore-sandbox.sh" > "$OUT" 2>&1
# 只看隧道那一段:其它服务本来就没跑,整篇 grep "➖ 已在运行" 会误命中 CPA 的端口判活。
# 断言取的区间止于 [5/6](隧道段结束),把 Clash 段排除在外 —— 否则以后 Clash 段
# 新增任何一句"已在运行"都会把这条断言拖下水,而它本来只在测隧道判活。
sed -n '/\[4\/6\]/,/\[6\/6\]/p' "$OUT" | sed 's/^/    /'
TUNNEL_SEC=$(sed -n '/\[4\/6\]/,/\[5\/6\]/p' "$OUT")
if printf '%s' "$TUNNEL_SEC" | grep -q "➖ 已在运行"; then
    fail "D: 把 watchdog 命令行误判成隧道进程(旧 bug 复现)"
else
    ok "D: 未误判 watchdog 命令行"
fi
printf '%s' "$TUNNEL_SEC" | grep -q "已在后台启动" && ok "D: 正确识别隧道不在跑并拉起" || fail "D: 未拉起隧道"
echo

# ---------- Clash 段的两条异常路径 ----------
# 公共铺垫:除 Clash 外全部预置为"已在运行",把跑一次的成本压到最低,也把断言
# 限制在 Clash 段自身 —— 其它段本来就不该因为 Clash 缺席而改变行为。
# $1=场景名 $2=破坏动作的函数名(在同一 shell 作用域里定义,直接用 $SB)
CASE_RC=0
run_clash_case() {
    build_sandbox
    "$2"
    : > "$VD/running"
    printf '%s\n' \
        "$SB/workspace/cpa/cli-proxy-api --config config.yaml" \
        "$SB/workspace/cc-connect/cc-connect --config $SB/workspace/cc-connect/config.toml" \
        "cloudflared tunnel run" >> "$VD/running"
    printf 'app_id = "cli_a1"\n' > "$SB/workspace/cc-connect/config.toml"
    printf '{"app_id":"cli_b2"}\n' > "$SB/workspace/feishu-bot/feishu-bot-config.json"
    echo "══ 场景:$1 ══"
    VERIFY_RUNNING="$VD/running" VERIFY_CPA_UP="1" PATH="$BIN:$PATH" \
        timeout 200 bash "$VD/restore-sandbox.sh" > "$OUT" 2>&1
    CASE_RC=$?
    sed -n '/\[5\/6\]/,/\[6\/6\]/p' "$OUT" | sed 's/^/    /'
}
drop_config() { rm -f "$SB/workspace/clash/config.yaml"; }
drop_installer() { rm -f "$SB/workspace/cc-connect/clash-install.sh"; }

# 场景 E:内核装过、订阅没投递 —— 容器里的常态(订阅含密钥,仓库里没有)
run_clash_case "E 缺订阅 config.yaml(应跳过,不影响其它服务)" drop_config
grep -q "未装或订阅未投递" "$OUT" && ok "E: 明确报出跳过原因" || fail "E: 未说明跳过原因"
[ -f "$SB/workspace/clash/installed.marker" ] && fail "E: 缺订阅仍调了安装脚本" || ok "E: 没有硬调安装脚本"
[ "$CASE_RC" = "0" ] && ok "E: 退出码 0,Clash 缺席没让恢复流程失败" || fail "E: 退出码 $CASE_RC"
grep -q "恢复流程执行完毕" "$OUT" && ok "E: 流程走到了结尾" || fail "E: 流程中途断了"
echo

# 场景 F:restore-all.sh 是新的,但脚本是旧 bootstrap 铺的 —— 必须指名怎么办,
# 而不是含糊地"跳过"(跳过会让人以为 Clash 没事,实际是脚本没到位)
run_clash_case "F 缺 clash-install.sh(应报错并给出重铺命令)" drop_installer
grep -q "安装脚本缺失" "$OUT" && ok "F: 报出脚本缺失" || fail "F: 未报出脚本缺失"
grep -q "bootstrap.sh" "$OUT" && ok "F: 给出了重铺脚本的命令" || fail "F: 没说清怎么补脚本"
[ -f "$SB/workspace/clash/installed.marker" ] && fail "F: 缺脚本仍调了安装" || ok "F: 没有硬调不存在的脚本"
echo

echo "══ 结果 ══"
[ "$FAIL" = "0" ] && echo "✅ 全部断言通过" || { echo "❌ 存在失败断言"; exit 1; }
