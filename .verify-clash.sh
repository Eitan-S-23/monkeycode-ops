#!/bin/bash
# =============================================================================
# 本地验证 clash-install.sh —— 在本机(Git Bash)用桩件跑通各条路径，不碰容器。
#
# 为什么要在本机跑：那个脚本要在容器里执行，而容器没有直达通道、跑一次的代价是
# 一整轮 base64 投递。pgrep 模式与实际命令行对不对得上、预检失败时退出码对不对，
# 这类问题只有真跑起来才看得见 —— 所以先在本地把能跑的分支都跑一遍。
#
# 做法：把脚本里的 CDIR 与判台路径 sed 成临时目录后执行，
#      注入 PATH 桩件模拟 uname/curl/pgrep/setsid/sleep。
#      sed 若没全部命中会断言失败，避免"测试默默什么都没测"。
#
# 所有产物都在 .verify-tmp/ 内，不写项目外任何位置。
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

SRC=clash-install.sh
# 订阅快照留在仓库外的 clash/ 里(它含节点密钥,不进仓库);本脚本随仓库走,
# 所以两者不同目录。缺了就直接失败,不静默退化成"少测几条"。
CFG="$HERE/../clash/config.yaml"
[ -f "$CFG" ] || { echo "❌ 找不到订阅快照 $CFG —— 静态检查没法跑"; exit 1; }

TMP="$HERE/.verify-tmp"
FAILED=0
PASS=0

rm -rf "$TMP"; mkdir -p "$TMP/bin"

pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ❌ $1"; echo "     —— 实际输出 ——"; printf '%s\n' "$2" | sed 's/^/     | /'; }
chk()  { if printf '%s' "$3" | grep -qF "$2"; then pass "$1"; else fail "$1" "$3"; fi; }
nchk() { if printf '%s' "$3" | grep -qF "$2"; then fail "$1" "$3"; else pass "$1"; fi; }

# -----------------------------------------------------------------------------
# 桩件。全部都从 $0 推出自己的目录 —— 桩件是独立进程，父脚本的变量传不进去。
# -----------------------------------------------------------------------------
STUBDIR='D="$(cd "$(dirname "$0")" && pwd)"; T="$(dirname "$D")"'

cat > "$TMP/bin/uname" <<EOF
#!/bin/bash
$STUBDIR
[ "\${1:-}" = "-m" ] && echo x86_64 || echo Linux
EOF

# pgrep -f <模式>：按**完整命令行**匹配，"内核在跑"的判据是状态文件里有这行。
# 被验证的正是这个匹配关系本身，所以这里照真实语义实现，不做简化。
cat > "$TMP/bin/pgrep" <<EOF
#!/bin/bash
$STUBDIR
[ "\${1:-}" = "-f" ] || exit 1
[ -s "\$T/running.cmdline" ] || exit 1
grep -qF "\$2" "\$T/running.cmdline" && echo 4242
EOF

# setsid：先把命令行记进状态文件（模拟进程起来了），再执行。
# 脚本若用相对路径启动，这里记下的就是 "./mihomo ..."，pgrep 便匹配不到 —— 那正是
# 要防的回归：重复执行会起出第二份内核，两个进程抢 7890 端口。
cat > "$TMP/bin/setsid" <<EOF
#!/bin/bash
$STUBDIR
printf '%s' "\$*" > "\$T/running.cmdline"
exec "\$@"
EOF

# sleep：空转，别让验证真的等 20 秒
cat > "$TMP/bin/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

# curl：模拟下载与控制端口探测。环境变量 CLASH_STUB_NET=fail 时一律失败。
cat > "$TMP/bin/curl" <<EOF
#!/bin/bash
$STUBDIR
[ "\${CLASH_STUB_NET:-ok}" = "fail" ] && exit 22
OUT=""; URL=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) OUT="\$2"; shift 2 ;;
        --max-time|-x|--connect-timeout|-w) shift 2 ;;
        http*) URL="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$URL" in
    *mihomo/releases*)
        # 内核下载：给一个**真的 gzip**，让 gunzip 那一步也真的被执行到
        printf '#!/bin/bash\n[ "\$1" = "-v" ] && echo "Mihomo Meta v1.19.31 linux amd64"\nexit 0\n' > "\$T/.fake-mihomo"
        gzip -c "\$T/.fake-mihomo" > "\$OUT" ;;
    *meta-rules-dat*) head -c 64 /dev/zero > "\$OUT" ;;
    */version*)       echo '{"version":"v1.19.31","meta":true}' ;;
    *gstatic*)        printf '204' ;;
    *baidu*)          printf '200' ;;
esac
exit 0
EOF
chmod +x "$TMP/bin"/*

# -----------------------------------------------------------------------------
# 把脚本的容器绝对路径改成本机临时目录。
# 改写条数是硬断言：上游一旦改了这两行，这里直接失败，而不是"测了个空脚本"。
# -----------------------------------------------------------------------------
build_variant() {
    sed -e "s#^CDIR=/workspace/clash#CDIR=$TMP/clash#" \
        -e "s#\[ -d /workspace/cc-connect \]#[ -d $TMP/cc-connect ]#" "$SRC" > "$1"
    local n
    n=$(grep -c -e "^CDIR=$TMP/clash" -e "\[ -d $TMP/cc-connect \]" "$1")
    [ "$n" = "2" ]
}

run() { PATH="$TMP/bin:$PATH" bash "$1" 2>&1; }

mkdir -p "$TMP/cc-connect"

echo "═══ 判台：改写正确性 ═══"
VAR="$TMP/variant.sh"
if build_variant "$VAR"; then pass "CDIR 与判台路径改写命中（2/2）"; else fail "路径改写未全部命中，验证失效" ""; fi

echo
echo "═══ 场景 A：全新安装 ═══"
rm -f "$TMP/running.cmdline"; rm -rf "$TMP/clash"; mkdir -p "$TMP/clash"
printf 'port: 7890\n  listen: 0.0.0.0:23453\n' > "$TMP/clash/config.yaml"
OUT=$(run "$VAR")
chk "A 架构识别为 amd64"        "mihomo 安装（amd64）" "$OUT"
chk "A 内核下载完成"             "mihomo v1.19.31 下载完成" "$OUT"
chk "A 内核是真 gzip、解压成功"   "内核就位：Mihomo Meta v1.19.31" "$OUT"
chk "A geoip.dat 就位"          "geoip.dat 下载完成" "$OUT"
chk "A 配置预检通过"             "配置预检通过" "$OUT"
chk "A 内核已拉起"               "内核已拉起（PID 4242）" "$OUT"
chk "A 国外经代理 204"           "b) 国外经代理：HTTP 204" "$OUT"
chk "A 国内分流直连 200"         "c) 国内经代理：HTTP 200" "$OUT"
chk "A 汇总里进程为运行中"        "运行中 PID 4242" "$OUT"
nchk "A 未误报缺 config"         "先把订阅 YAML 投递进去" "$OUT"
chk "A 生成的 proxy.env 含端口"   "7890" "$(cat "$TMP/clash/proxy.env" 2>/dev/null)"
chk "A 订阅里的 DNS 已收敛本机"    "listen: 127.0.0.1:23453" "$(cat "$TMP/clash/config.yaml")"

echo
echo "═══ 场景 B：幂等重跑（不该重复下载、不该起第二份）═══"
OUT=$(run "$VAR")
chk "B 跳过内核下载"             "已有内核" "$OUT"
chk "B 跳过 geoip.dat"           "已有 geoip.dat" "$OUT"
chk "B 识别为已在运行"            "内核已在运行（PID 4242）" "$OUT"
nchk "B 没有再拉起一次"           "内核已拉起" "$OUT"

echo
echo "═══ 场景 C：认错机器（缺判台标志）═══"
mv "$TMP/cc-connect" "$TMP/cc-connect.bak"
OUT=$(run "$VAR")
chk "C 硬停并指出不是 MonkeyCode"  "这不是 MonkeyCode 容器" "$OUT"
nchk "C 没有继续下载"             "mihomo 安装" "$OUT"
mv "$TMP/cc-connect.bak" "$TMP/cc-connect"

echo
echo "═══ 场景 D：缺 config.yaml ═══"
mv "$TMP/clash/config.yaml" "$TMP/config.bak"
OUT=$(run "$VAR")
chk "D 提示先投递订阅"            "先把订阅 YAML 投递进去" "$OUT"
nchk "D 没有硬撑着往下走"          "配置预检" "$OUT"
mv "$TMP/config.bak" "$TMP/clash/config.yaml"

echo
echo "═══ 场景 E：容器出网全挂（内核下载失败）═══"
rm -rf "$TMP/clash"; mkdir -p "$TMP/clash"; printf 'port: 7890\n' > "$TMP/clash/config.yaml"
rm -f "$TMP/running.cmdline"
export CLASH_STUB_NET=fail
OUT=$(run "$VAR")
unset CLASH_STUB_NET
chk "E 明确报出网被挡并停住"       "内核下载失败" "$OUT"
nchk "E 没有硬撑着往下走"          "配置预检" "$OUT"

echo
echo "═══ 静态检查 ═══"
if bash -n "$SRC"; then pass "语法检查通过"; else fail "语法检查失败" ""; fi

if grep -qF 's#^  listen: 0\.0\.0\.0:#  listen: 127.0.0.1:#' "$SRC"; then
    pass "保留了 DNS 监听收敛为 127.0.0.1 的动作"
else
    fail "DNS 收敛的 sed 不见了" "$(grep -n 'listen' "$SRC")"
fi

# 启动必须是绝对路径 —— 否则命令行是 "./mihomo ..."，pgrep -f "$CDIR/mihomo" 失配
if grep -qF 'setsid nohup "$CDIR/mihomo"' "$SRC"; then
    pass "启动使用绝对路径（pgrep 模式能匹配上）"
else
    fail "启动未使用绝对路径，pgrep 会失配" "$(grep -n 'setsid' "$SRC")"
fi

# 订阅必须是完整可跑的：顶层键、Default Proxy 组、GEOIP 规则
# CFG 已在文件头指向 ../clash/config.yaml(订阅不在本目录)
for k in "proxies:" "proxy-groups:" "rules:" "dns:"; do
    if grep -qE "^$k" "$CFG"; then pass "订阅含顶层 $k"; else fail "订阅缺顶层 $k" ""; fi
done
if grep -qE "^  - name: Default Proxy" "$CFG"; then
    pass "Default Proxy 组存在（rules 末尾 MATCH 指向它）"
else
    fail "缺 Default Proxy 组，rules 的 MATCH 会指向不存在的组" ""
fi
if grep -qE "GEOIP,(CN|PRIVATE)" "$CFG"; then
    pass "含 GEOIP 规则（所以容器里必须放 geoip 数据）"
else
    fail "没找到 GEOIP 规则，geoip 数据那步可能多余" ""
fi
n=$(awk 'f&&/^- /{n++} /^rules:/{f=1} END{print n+0}' "$CFG")
if [ "$n" -gt 1000 ]; then pass "规则条数 $n（分流规则完整）"; else fail "规则只有 $n 条，疑似订阅被截断" ""; fi

echo
echo "═══════════════════════════════════════════"
echo "  通过 $PASS 项，失败 $FAILED 项"
echo "═══════════════════════════════════════════"
[ "$FAILED" = 0 ] || exit 1
