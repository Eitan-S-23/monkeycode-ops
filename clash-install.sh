#!/bin/bash
# =============================================================================
# MonkeyCode 容器：安装并启动 mihomo(Clash.Meta)，跑 GLaDOS 订阅配置
#
# 在哪跑：容器内。本文件随仓库走，bootstrap.sh 会把它铺到 /workspace/cc-connect/。
# 幂等：重复跑不会起出第二份；内核与规则库已存在就不重复下载。
#
# 用法（在容器里）：
#   mkdir -p /workspace/clash
#   <先投递 config.yaml 到 /workspace/clash/config.yaml>
#   bash /workspace/cc-connect/clash-install.sh
#
# restore-all.sh 会自动调用本脚本（幂等，已跑着就跳过），一般不需要手工执行。
# 唯一必须手工的一步是投递 config.yaml —— 它含节点密钥，仓库里刻意没有。
#
# 装完得到：
#   /workspace/clash/mihomo        内核二进制
#   /workspace/clash/config.yaml   GLaDOS 订阅（唯一改动：dns.listen 由 0.0.0.0 改为 127.0.0.1）
#   /workspace/clash/geoip.dat     规则库（dat 格式）
#   /workspace/clash/geoip.metadb  规则库（mmdb 格式；两种 geodata 模式各备一份，省得猜）
#   /workspace/clash/proxy.env     环境变量，source 一下就走上代理
#   /workspace/clash/clash.log     运行日志
#
# 本机没有直达通道，容器重启后 /workspace 里的文件还在、进程不会自己回来，
# 所以恢复时重跑本脚本即可（不会重新下载）。
# =============================================================================

set -uo pipefail

CDIR=/workspace/clash
VER=v1.19.31
PROXY_PORT=7890
CTRL_PORT=9090

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }

# -----------------------------------------------------------------------------
# 0. 判台：认错机器就硬停。腾讯那台跑 new-api，标志是 /workspace/run-new-api.sh，
#    在它上面装 clash 毫无意义，还会白烧浏览器额度。
# -----------------------------------------------------------------------------
[ -d /workspace/cc-connect ] || die "这不是 MonkeyCode 容器（缺 /workspace/cc-connect）。停手，先判台。"

# -----------------------------------------------------------------------------
# 1. 架构
# -----------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64; PKG="amd64-compatible" ;;
    aarch64|arm64) ARCH=arm64; PKG="arm64" ;;
    *) die "不支持的架构：$(uname -m)" ;;
esac

mkdir -p "$CDIR" || die "建不出 $CDIR"
echo "═══ mihomo 安装（$ARCH）═══"

# -----------------------------------------------------------------------------
# 2. 取文件
#
#    容器里 raw.githubusercontent.com 通（bootstrap.sh 靠它），但 release 资产走
#    的是 objects.githubusercontent.com，不保证通。所以按顺序试直连 + 几个反代，
#    哪个通用哪个。--max-time 给得宽，10MB 的规则库在慢线上别提前掐断。
# -----------------------------------------------------------------------------
BASES=(
    "https://github.com"
    "https://ghfast.top/https://github.com"
    "https://gh-proxy.com/https://github.com"
    "https://ghproxy.net/https://github.com"
    "https://hub.gitmirror.com/https://github.com"
)

fetch() {  # $1=github 路径  $2=落地文件  $3=说明
    local path="$1" out="$2" desc="$3" base
    [ -s "$out" ] && { echo "  ⏭  已有 $desc"; return 0; }
    for base in "${BASES[@]}"; do
        echo "  → $desc @ ${base%%/https*}"
        if curl -fL --connect-timeout 8 --max-time 600 -o "$out.part" "$base/$path" 2>/dev/null; then
            mv "$out.part" "$out" && { ok "$desc 下载完成（$(wc -c < "$out") 字节）"; return 0; }
        fi
        rm -f "$out.part"
    done
    echo "  ✗ $desc 所有镜像都没拿到"
    return 1
}

# 内核。amd64 特意选 compatible 版（不带 v1/v2/v3 微架构指令集要求），
# 虚拟机 CPU 型号不确定时最稳。
if [ -x "$CDIR/mihomo" ]; then
    echo "  ⏭  已有内核：$("$CDIR/mihomo" -v 2>/dev/null | head -1)"
else
    fetch "MetaCubeX/mihomo/releases/download/$VER/mihomo-linux-$PKG-$VER.gz" "$CDIR/mihomo.gz" "mihomo $VER" \
        || die "内核下载失败：容器出网被挡。先解决出网，或换镜像重试。"
    gunzip -c "$CDIR/mihomo.gz" > "$CDIR/mihomo.new" \
        || die "解压失败：$CDIR/mihomo.gz 不是有效 gzip（多半下到了错误页）"
    chmod +x "$CDIR/mihomo.new" && mv "$CDIR/mihomo.new" "$CDIR/mihomo" && rm -f "$CDIR/mihomo.gz"
    ok "内核就位：$("$CDIR/mihomo" -v 2>/dev/null | head -1)"
fi

# 规则库。订阅规则里有 GEOIP,CN 与 GEOIP,PRIVATE，少了规则库 mihomo 起不来。
# dat 与 metadb 两种格式都备一份：geodata-mode 取哪个值由 mihomo 默认决定，
# 不赌它，直接两份都放好。
fetch "MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"    "$CDIR/geoip.dat"    "geoip.dat" \
    || die "geoip.dat 拿不到：没有它 GEOIP,CN 规则无法加载，内核会拒绝启动。"
fetch "MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" "$CDIR/geoip.metadb" "geoip.metadb" \
    || warn "geoip.metadb 没拿到；若内核日志报缺 mmdb 再补。"

# -----------------------------------------------------------------------------
# 3. 配置
# -----------------------------------------------------------------------------
[ -s "$CDIR/config.yaml" ] || die "缺 $CDIR/config.yaml。先把订阅 YAML 投递进去再跑本脚本。"

# 订阅原本把 DNS 监听在 0.0.0.0:23453。容器里没必要对外开 DNS，收到本机。
sed -i 's#^  listen: 0\.0\.0\.0:#  listen: 127.0.0.1:#' "$CDIR/config.yaml"

echo
echo "═══ 配置预检 ═══"
# 刻意不用 `mihomo -t | tail`：管道的退出码是 tail 的，配置错了也会被判成通过。
TEST_OUT=$("$CDIR/mihomo" -t -d "$CDIR" -f "$CDIR/config.yaml" 2>&1)
if [ $? -ne 0 ]; then
    echo "$TEST_OUT" | tail -6
    die "配置预检没过（见上）。内核不会带着坏配置启动。"
fi
echo "$TEST_OUT" | tail -2
ok "配置预检通过"

# -----------------------------------------------------------------------------
# 4. 环境变量文件
#
#    题外话但值得说清：容器里没有"系统代理"这一层，装上 clash 不等于所有程序
#    自动走代理。要哪个程序走，就 source 这个文件再跑它。
# -----------------------------------------------------------------------------
cat > "$CDIR/proxy.env" <<'EOF'
# 用法：source /workspace/clash/proxy.env
# 取消：unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7891
export no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" ALL_PROXY="$all_proxy" NO_PROXY="$no_proxy"
EOF
ok "环境变量文件：$CDIR/proxy.env"

# -----------------------------------------------------------------------------
# 5. 启动
# -----------------------------------------------------------------------------
if pgrep -f "$CDIR/mihomo" >/dev/null 2>&1; then
    echo "  ⏭  内核已在运行（PID $(pgrep -f "$CDIR/mihomo" | head -1)）"
else
    # 必须用绝对路径启动，否则命令行是 "./mihomo -d /workspace/clash"，
    # 上面那句 pgrep -f "/workspace/clash/mihomo" 匹配不到 —— 重复执行就会
    # 起出第二份内核，两个进程抢 7890 端口，现场表现为"重启后代理时好时坏"。
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$CDIR/mihomo" -d "$CDIR" >> "$CDIR/clash.log" 2>&1 < /dev/null &
    else
        nohup "$CDIR/mihomo" -d "$CDIR" >> "$CDIR/clash.log" 2>&1 < /dev/null &
    fi
    sleep 1
    pgrep -f "$CDIR/mihomo" >/dev/null 2>&1 \
        && ok "内核已拉起（PID $(pgrep -f "$CDIR/mihomo" | head -1)）" \
        || die "内核没起来，看 $CDIR/clash.log 尾部：$(tail -3 "$CDIR/clash.log" 2>/dev/null)"
fi

# -----------------------------------------------------------------------------
# 6. 验证
#
#    分三段查，好在失败时直接指出是哪一层的问题：
#      a) 控制端口     —— 内核自身活着没
#      b) 国外经代理   —— 节点通不通（走 rules，MATCH,Default Proxy）
#      c) 国内经代理   —— 分流生效没（命中 GEOIP,CN,DIRECT，应当直连返回）
# -----------------------------------------------------------------------------
echo
echo "═══ 验证 ═══"

for _ in $(seq 1 20); do
    curl -s --max-time 2 "http://127.0.0.1:$CTRL_PORT/version" >/dev/null 2>&1 && break
    sleep 1
done

CTRL=$(curl -s --max-time 3 "http://127.0.0.1:$CTRL_PORT/version" 2>/dev/null | head -c 80)
[ -n "$CTRL" ] && ok "a) 控制端口 $CTRL_PORT 响应：$CTRL" \
               || warn "a) 控制端口 $CTRL_PORT 无响应 —— 内核可能刚起来还没就绪，看 clash.log"

ABROAD=$(curl -s -o /dev/null -w '%{http_code}' -x "http://127.0.0.1:$PROXY_PORT" --max-time 25 \
         "https://www.gstatic.com/generate_204" 2>/dev/null)
[ "$ABROAD" = "204" ] && ok "b) 国外经代理：HTTP $ABROAD（节点可用）" \
                      || warn "b) 国外经代理：HTTP ${ABROAD:-无响应}（节点不通或订阅过期）"

DOMESTIC=$(curl -s -o /dev/null -w '%{http_code}' -x "http://127.0.0.1:$PROXY_PORT" --max-time 15 \
           "https://www.baidu.com" 2>/dev/null)
case "$DOMESTIC" in
    200|301|302) ok "c) 国内经代理：HTTP $DOMESTIC（命中 GEOIP,CN,DIRECT，分流正常）" ;;
    *)           warn "c) 国内经代理：HTTP ${DOMESTIC:-无响应}（分流或容器本身出网有问题）" ;;
esac

# -----------------------------------------------------------------------------
# 7. 汇总
# -----------------------------------------------------------------------------
cat <<EOF

═══ 汇总 ═══
  目录        $CDIR
  内核        $([ -x "$CDIR/mihomo" ] && "$CDIR/mihomo" -v 2>/dev/null | head -1 || echo 缺失)
  进程        $(pgrep -f "$CDIR/mihomo" >/dev/null 2>&1 && echo "运行中 PID $(pgrep -f "$CDIR/mihomo" | head -1)" || echo 未运行)
  规则库      geoip.dat $([ -s "$CDIR/geoip.dat" ] && echo OK || echo 缺失) / geoip.metadb $([ -s "$CDIR/geoip.metadb" ] && echo OK || echo 缺失)
  HTTP 代理   127.0.0.1:$PROXY_PORT
  SOCKS 代理  127.0.0.1:7891
  控制 API    http://127.0.0.1:$CTRL_PORT  (切节点：GET /proxies/Default%20Proxy)

用法：
  source $CDIR/proxy.env          # 之后本 shell 里的 curl/git/pip 走代理
  curl -x http://127.0.0.1:$PROXY_PORT https://www.google.com   # 单条命令走代理
  bash $0  # 容器重启后再跑一次，幂等（$0 即本脚本实际路径）

EOF
