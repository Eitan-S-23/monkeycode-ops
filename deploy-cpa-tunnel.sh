#!/bin/bash
# CPA 管理界面外网暴露:Cloudflare Tunnel(在容器内运行)
#
# 原理:CPA(cli-proxy-api)监听容器内的 8317,只有本机能访问。容器在平台内网里
# 只出网、无入网,所以"对外暴露服务"只能由容器这一侧发起 —— cloudflared 主动
# 连到 Cloudflare 边缘建立长连接,再把 127.0.0.1:8317 挂到这条连接上。
# 域名只是给这条连接一个固定地址,本身不产生任何通路。
#
# 两种模式,按是否提供 CPA_TUNNEL_TOKEN 自动判定:
#
# 【quick 模式】不填 token —— 不用 CF 账号、不用域名,云端返回一个
#   https://xxx.trycloudflare.com 临时地址。用途:先证明"容器连得上 CF 边缘"。
#   地址每次重启都变,且完全公开(谁拿到 URL 谁能用),不适合长期。
#
# 【named 模式】推荐 —— 隧道建在 CF 控制台,绑定你自己的域名,token 填进 bots.env。
#   地址固定,可以给这条域名挂 Cloudflare Access 登录。
#
#   CF 控制台步骤(一次性):
#     1. 域名已托管在 CF(域名的 NS 已指向 Cloudflare)
#     2. Zero Trust → Networks → Tunnels → Create a tunnel → 选 Cloudflared
#     3. 复制页面给出的 token(形如 eyJ... 的长串)
#     4. Public Hostname 加一条:子域 cpa + 你的域名,Service 选 HTTP,
#        URL 填 127.0.0.1:8317   ← 填容器本地地址,不是公网地址
#     5. 强烈建议:同一条 hostname 上加 Access 策略(Email OTP 即可)。
#        面板能读改上游凭证,不加登录等于知道域名的人都能用。
#
# 用法(容器内):
#     cd /workspace/cc-connect
#     echo 'CPA_TUNNEL_TOKEN=eyJ...' >> bots.env     # 走 named 模式才需要这行
#     nohup bash deploy-cpa-tunnel.sh > cpa-tunnel.log 2>&1 < /dev/null &
#
# 看结果:
#     tail -30 /workspace/cc-connect/cpa-tunnel.log    # quick 模式的地址在这里
#     浏览器打开 https://cpa.你的域名/management.html   # named 模式
#
# 停止(脚本跑完会按实际路径再打一遍这两条):
#     touch /workspace/cloudflared-state/.stop
#     pkill -f '^/workspace/cloudflared-state'   # ^ 锚定,裸 -f 会命中 watchdog
#
# 路径说明:二进制与运行状态分开放 —— 二进制优先复用机器上已有的,没有再下载到
# /workspace/bin/cloudflared;日志/watchdog/启动器一律在 /workspace/cloudflared-state。
# 不往 /workspace/cloudflared 写任何东西:那里可能已经躺着一个手工下载的同名文件。
#
# 端口由你决定:CPA_PORT 默认 8317 —— 依据是容器内 ss 实测 cli-proxy-api 监听
# *:8317,不是脚本猜的。换端口就设 CPA_PORT。
#
# 设计要点:
# 1) token 只落在 state 目录的 run.sh(权限 700),不出现在 ps 命令行里。
# 2) 容器无 systemd,复用 flock + 循环 watchdog 保活(与 cc-connect 同一套做法)。
# 3) 下载慢/不通时设 CF_MIRROR(前缀)或直接手工把二进制放到 /workspace/bin/cloudflared。
# 4) QUIC 连不上(UDP 被网络拦,容器里常见)时自动改用 http2 重试,无需手工干预。
#    成功判据是"边缘连接已注册",不是"拿到地址" —— cloudflared 先分配地址再连边缘,
#    只看地址会把连不上的情况误报成已建立。

set -uo pipefail

CC_DIR=/workspace/cc-connect
CF_STATE=/workspace/cloudflared-state
RUN_SH="$CF_STATE/run.sh"
LOG="$CF_STATE/tunnel.log"
ENV_FILE="$CC_DIR/bots.env"
# 只做透传占位,默认值一律等 bots.env 加载完再补 —— 在这之前赋默认值会让
# 加载器把"文件里写了值"误判成"命令行已给值",从而静默忽略文件配置。
CPA_PORT="${CPA_PORT:-}"
CF_PROTOCOL="${CF_PROTOCOL:-}"
CF_MIRROR="${CF_MIRROR:-}"

mkdir -p "$CF_STATE"

# 配置从 bots.env 加载(与 deploy-codex.sh 同一套读法):避免密钥出现在命令行,
# 那会同时落进 shell 历史和 ps 输出。已由命令行显式传入的变量优先。
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="${key%$'\r'}"; key="${key#"${key%%[![:space:]]*}"}"
        value="${value%$'\r'}"
        [ -z "$key" ] && continue
        case "$key" in \#*) continue ;; esac
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "  ⚠️ bots.env 跳过非法键名: $key"; continue; }
        [ -n "${!key:-}" ] && continue   # 命令行已给值,不覆盖
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        export "$key=$value"
    done < "$ENV_FILE"
    echo "  ✅ 已从 $ENV_FILE 加载配置"
fi

CPA_TUNNEL_TOKEN="${CPA_TUNNEL_TOKEN:-}"
CPA_PORT="${CPA_PORT:-8317}"

if [ -n "$CPA_TUNNEL_TOKEN" ]; then
    MODE=named
else
    MODE=quick
fi
echo "  模式:$MODE"

# ---------- 1. 先确认后端真的在,并探出面板路径 ----------
echo "[1/4] 检查本地 CPA(127.0.0.1:$CPA_PORT)..."
if curl -s -o /dev/null -m 5 "http://127.0.0.1:$CPA_PORT/"; then
    echo "  ✅ 有响应"
    for path in / /management.html; do
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$CPA_PORT$path" 2>/dev/null || echo "000")
        echo "     $path → HTTP $code"
    done
else
    echo "  ⚠️ 无响应 —— 确认 CPA 在跑;端口不是 8317 就设 CPA_PORT 后重跑"
    echo "     隧道仍会启动,只是外网打开时会 502"
fi

# ---------- 2. 准备 cloudflared:先找,找不到才下载 ----------
echo "[2/4] 准备 cloudflared..."

# 判定一个路径是不是真能用的 cloudflared(存在、可执行、--version 认自己是它)
usable_cf() {
    [ -n "${1:-}" ] && [ -f "$1" ] || return 1
    [ -x "$1" ] || chmod +x "$1" 2>/dev/null
    "$1" --version 2>&1 | grep -qi cloudflared
}

CF_BIN=""
for cand in \
    /workspace/cloudflared \
    /workspace/bin/cloudflared \
    /workspace/cloudflared/cloudflared \
    /usr/local/bin/cloudflared \
    /usr/bin/cloudflared \
    "$(command -v cloudflared 2>/dev/null || true)"
do
    if usable_cf "$cand"; then
        CF_BIN="$cand"
        echo "  ✅ 复用已装好的:$CF_BIN($("$CF_BIN" --version 2>&1 | head -1))"
        break
    fi
done

if [ -z "$CF_BIN" ]; then
    # 诊断:同名文件存在但不可用是最容易让人摸不着头脑的情况,把线索直接摊开
    if [ -e /workspace/cloudflared ] && [ ! -d /workspace/cloudflared ]; then
        echo "  ⚠️ /workspace/cloudflared 存在但不是可用的 cloudflared,内容开头如下:"
        ls -l /workspace/cloudflared | sed 's/^/     /'
        head -c 120 /workspace/cloudflared 2>/dev/null | tr -d '\0' | sed 's/^/     /'
        echo
    fi
    case "$(uname -m)" in
        x86_64 | amd64) CF_ARCH=amd64 ;;
        aarch64 | arm64) CF_ARCH=arm64 ;;
        *) echo "❌ 未知架构 $(uname -m),请手工放一份 cloudflared 到 /workspace/bin/cloudflared"; exit 1 ;;
    esac
    mkdir -p /workspace/bin
    URL="${CF_MIRROR}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
    echo "  下载 $URL"
    echo "  (约 38MB。不设总时长上限,但低于 8KB/s 持续 90 秒会中止 —— 那样请设 CF_MIRROR)"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            --speed-limit 8192 --speed-time 90 \
            -o /workspace/bin/cloudflared.tmp "$URL"; then
        chmod +x /workspace/bin/cloudflared.tmp
        if usable_cf /workspace/bin/cloudflared.tmp; then
            mv /workspace/bin/cloudflared.tmp /workspace/bin/cloudflared
            CF_BIN=/workspace/bin/cloudflared
            echo "  ✅ $("$CF_BIN" --version 2>&1 | head -1)"
        else
            echo "  ❌ 下载完成但不是可用的 cloudflared(多半是错误页或被截断),开头内容:"
            head -c 120 /workspace/bin/cloudflared.tmp | tr -d '\0' | sed 's/^/     /'
            echo
            rm -f /workspace/bin/cloudflared.tmp
        fi
    fi
    if [ -z "$CF_BIN" ]; then
        echo "  ❌ 无法取得 cloudflared。两条路:"
        echo "     1) 设 CF_MIRROR 指向可达镜像前缀后重跑,例如 CF_MIRROR=https://你的前缀/"
        echo "     2) 手工把二进制放到 /workspace/bin/cloudflared 并 chmod +x,再重跑本脚本"
        exit 1
    fi
fi

# ---------- 3. 生成启动器(start/should 分离,便于 QUIC 失败时自动换 http2) ----------
echo "[3/4] 写入启动器与 watchdog..."

# 生成 run.sh。参数是协议名(空 = cloudflared 默认 QUIC)。
# token 只落在这个文件里(权限 700),不进 ps 命令行。
write_run_sh() {
    local proto_arg=""
    [ -n "$1" ] && proto_arg="--protocol $1"
    if [ "$MODE" = "named" ]; then
        cat > "$RUN_SH" <<EOF
#!/bin/bash
# cloudflared 启动器:token 只存在于本文件(700),不出现在 ps 命令行里
export HOME="\${HOME:-/root}"
exec "$CF_BIN" tunnel --no-autoupdate $proto_arg run --token '$CPA_TUNNEL_TOKEN'
EOF
    else
        cat > "$RUN_SH" <<EOF
#!/bin/bash
# cloudflared 启动器(quick 模式:无 token,地址每次重启都变)
export HOME="\${HOME:-/root}"
exec "$CF_BIN" tunnel --no-autoupdate $proto_arg --url "http://127.0.0.1:$CPA_PORT"
EOF
    fi
    chmod 700 "$RUN_SH"
}

# 停掉 cloudflared 本体与上一轮 watchdog。watchdog 的 bash -c 正文里含 .stop
# 路径判断,故按该路径匹配即可命中;本脚本自身 argv 不含它,不会自杀。
stop_tunnel() {
    pkill -f "$CF_STATE/.stop" 2>/dev/null || true
    pkill -f "^$CF_BIN" 2>/dev/null || true
    sleep 3
}

start_tunnel() {   # $1 = 协议(空 = 默认 QUIC)
    write_run_sh "$1"
    : > "$LOG"     # 清空日志:每次尝试的判据只看本轮,不混上上次的报错
    rm -f "$CF_STATE/.stop"
    nohup flock -n "$CF_STATE/.lock" bash -c "
        while true; do
            [ -f '$CF_STATE/.stop' ] && { echo \"[\$(date '+%F %T')] 检测到 .stop,watchdog 退出\"; break; }
            bash '$RUN_SH' >> '$LOG' 2>&1
            echo \"[\$(date '+%F %T')] cloudflared 退出,10 秒后重启\" >> '$LOG'
            sleep 10
        done
    " >/dev/null 2>&1 &
}

# 成功判据是"边缘连接已注册",不是"拿到了地址" —— cloudflared 先分配
# trycloudflare 地址、再去连边缘,只看地址会把连不上的情况误报成已建立。
wait_connected() {
    local i
    for i in $(seq 1 30); do
        sleep 2
        grep -qE 'Registered tunnel connection' "$LOG" 2>/dev/null && return 0
        # QUIC 明确打不通且没指定协议时,不必耗满 60 秒
        if [ -z "$CF_PROTOCOL" ] && grep -qE 'Failed to dial a quic connection' "$LOG" 2>/dev/null; then
            return 1
        fi
    done
    return 1
}

# ---------- 4. 起隧道:先按默认/指定协议,QUIC 不通就自动换 http2 ----------
USED_PROTO="${CF_PROTOCOL:-默认(QUIC)}"
stop_tunnel
start_tunnel "$CF_PROTOCOL"
echo "[4/4] 等待边缘连接注册(最多 60 秒)..."
CONNECTED=0
if wait_connected; then
    CONNECTED=1
elif [ -z "$CF_PROTOCOL" ]; then
    echo "  ⚠️ QUIC 连不上(多见于 UDP 被网络拦),自动改用 http2 重试..."
    stop_tunnel
    start_tunnel http2
    USED_PROTO=http2
    echo "  等待边缘连接注册(最多 60 秒)..."
    wait_connected && CONNECTED=1
fi

echo
echo "=== 最近日志 ==="
tail -20 "$LOG" 2>/dev/null || echo "(暂无日志)"
echo "================"
echo

echo "  本次使用协议:$USED_PROTO"
echo

if ! pgrep -f "^$CF_BIN" >/dev/null; then
    echo "❌ cloudflared 进程不在,停止/清理:touch $CF_STATE/.stop"
    exit 1
fi

URL=""
[ "$MODE" = "quick" ] && URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -1)

if [ "$CONNECTED" = "1" ]; then
    if [ "$MODE" = "quick" ]; then
        echo "✅ 边缘连接已注册,临时代理可用:"
        echo "   $URL/management.html"
        echo "   ⚠️ 这个地址完全公开且重启后会变,只适合验证通路。"
        echo "      长期使用请在 CF 控制台建隧道、绑自己的域名,把 token 填进 $ENV_FILE。"
    else
        echo "✅ 边缘连接已注册,地址是你自己在 CF 控制台配的 public hostname"
        echo "   浏览器打开 https://<你的子域>.<你的域名>/management.html"
    fi
else
    # 地址已分配但边缘没连上:明确说清楚,避免又被误当成"已建立"
    echo "❌ 边缘连接未注册 —— 隧道没通。"
    [ -n "$URL" ] && echo "   (日志里那个 $URL 是分配好的地址,但现在连不上,打不开)"
    echo "   已试过的协议:${CF_PROTOCOL:-默认(QUIC)→ http2}"
    echo "   若两种协议都不通,是容器出网被限制到 443/7844 之外,换域名也救不了 ——"
    echo "   把上面这段日志发我,我按具体报错判断。"
    exit 1
fi

echo
echo "=== 停止方式 ==="
echo "   touch $CF_STATE/.stop && pkill -f '^$CF_BIN'"
echo
echo "=== CPA 实际在用的配置(决定面板能否被非本机访问) ==="
# 先问进程:它才是唯一权威 —— config.example.yaml 是示例文件,拿它当依据会误导
CPA_PID=$(pgrep -f 'cli-proxy-api' | head -1)
if [ -n "$CPA_PID" ]; then
    echo "  进程 $CPA_PID:$([ -r /proc/$CPA_PID/cmdline ] && tr '\0' ' ' < /proc/$CPA_PID/cmdline)"
    echo "  工作目录:$(readlink /proc/$CPA_PID/cwd 2>/dev/null || echo 未知)"
else
    echo "  ⚠️ 没找到 cli-proxy-api 进程"
fi
echo "  --- /workspace/cpa 目录 ---"
ls -la /workspace/cpa 2>/dev/null | sed 's/^/  /' || echo "  (无此目录)"
echo "  --- 实际配置里的 remote-management 段(排除示例文件) ---"
CFG_HITS=$(grep -rniE 'allow-remote|remote-management|secret-key' /workspace/cpa \
    --include='*.yaml' --include='*.yml' --include='*.json' 2>/dev/null \
    | grep -v 'config\.example' | head -15)
if [ -n "$CFG_HITS" ]; then
    echo "$CFG_HITS" | sed 's/^/  /'
else
    echo "  (实际配置里没有这一段 —— 说明走的是默认值:allow-remote 为 false,面板拒绝非本机请求)"
fi
echo
echo "把上面这段发我。若确实缺 remote-management 段,我按你实际用的配置文件名给你补哪几行。"
