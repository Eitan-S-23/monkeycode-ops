#!/bin/bash
# 容器重启后一键恢复:把 MonkeyCode 容器里的常驻服务一次性拉起来
#
# 用法(容器内):
#     bash /workspace/cc-connect/restore-all.sh
# 想留日志:
#     nohup bash /workspace/cc-connect/restore-all.sh > /workspace/cc-connect/restore.log 2>&1 < /dev/null &
#
# ── 为什么需要这个脚本 ───────────────────────────────────────────────
# 本容器没有任何开机自启机制。这不是猜的,是在 MonkeyCode 平台源码里逐项查过的:
#   · backend/pkg/taskflow/types.go:123   创建 VM 的请求结构全字段中,
#                                        没有启动脚本/开机命令类字段
#   · frontend/src/api/Api.ts:540         前端创建环境唯一的环境级开关是
#                                        install_coding_agents(装不装编码 agent)
#   · 全仓库检索 .bashrc / profile.d / rc.local / crontab / init.d → 零命中
#   · backend/biz/host/handler/v1/internal.go:107-119  host 侧内部接口无 boot 钩子
# 结论:容器一重启,所有进程都不会自己回来 —— /workspace 里的文件还在,但没人执行。
# 手工跑一次本脚本即可全部复原,脚本本身幂等,重复跑不会起出第二份。
#
# ── 恢复哪四样(每样都先判活,在跑就跳过) ─────────────────────────────
#   [1/5] CPA 本体      /workspace/cpa/cli-proxy-api     平台不代管,自己起
#   [2/5] cc-connect    /workspace/cc-connect            codex + claude 两个机器人
#   [3/5] 自研 bot      /workspace/feishu-bot            原有机器人(仅新建机器人模式下)
#   [4/5] CPA 隧道      /workspace/cloudflared-state     管理面板对外暴露(依赖 [1/5])
#   [5/5] 汇总
#
# ── 设计要点 ────────────────────────────────────────────────────────
# 1) 幂等靠"进程判活",不靠状态文件 —— 重启后状态文件可能还在但进程早没了,
#    反之亦然。判活一律 pgrep 锚定可执行文件绝对路径。
# 2) pkill/pgrep 的 -f 一律加 ^ 锚定:裸 -f 会子串命中 watchdog 的 bash -c
#    命令行(里面含同样路径字样),把拉起者自己一起杀掉。
# 3) 只拉起进程,不重新生成配置。run.sh / config.toml / bots.env 缺失时
#    报错并指名该先跑哪个脚本 —— 恢复脚本重造配置只会把问题掩盖成更难查的故障。
# 4) cc-connect 与自研 bot 能否同跑,取决于当初的部署模式:
#    · 新建机器人模式:两者用不同的飞书 App,可以同跑 —— 都拉起来
#    · 复用模式:cc-connect 占的就是自研 bot 那个 App,同跑会两边抢长连接
#      —— 只拉 cc-connect,不碰 bot
#    判据是 app_id 是否重合(飞书一个 App 同一时刻只允许一条长连接),不是靠猜。
# 5) 保活沿用既有的 flock -n + 循环 watchdog,容器无 systemd。
#
# ── 停止 ────────────────────────────────────────────────────────────
#   touch /workspace/cc-connect/.stop            # 停 cc-connect 与其 watchdog
#   touch /workspace/cloudflared-state/.stop      # 停隧道与其 watchdog
#   touch /workspace/feishu-bot/.stop             # 停自研 bot
#   pkill -f '^/workspace/cpa/cli-proxy-api'      # 停 CPA(其 watchdog 会再拉起,
#                                                 #  要彻底停就先 touch /workspace/cpa/.stop)

set -uo pipefail

CC_DIR=/workspace/cc-connect
BOT_DIR=/workspace/feishu-bot
CPA_DIR=/workspace/cpa
CF_STATE=/workspace/cloudflared-state
CPA_PORT="${CPA_PORT:-8317}"

cd "$CC_DIR" 2>/dev/null || { echo "❌ 目录不存在: $CC_DIR"; exit 1; }

# 统一的判活:进程名按绝对路径锚定,避免命中 watchdog 的 bash -c 命令行
alive() { pgrep -f "^$1" >/dev/null 2>&1; }

# CPA 的判活要单独写:它的 argv[0] 是相对路径(容器内实测为
# "./cli-proxy-api --config config.yaml"),用 ^/workspace/cpa/... 锚定匹配不上。
# 故按进程名精确匹配(-x),再兜一层端口探测 —— 进程在但配置错时端口照样不通,
# 反过来端口通就一定有人在服务。
cpa_alive() {
    pgrep -x cli-proxy-api >/dev/null 2>&1 && return 0
    curl -s -o /dev/null -m 3 "http://127.0.0.1:$CPA_PORT/" 2>/dev/null && return 0
    return 1
}

# cloudflared 同理:它的 watchdog bash -c 正文里含 "cloudflared-state/tunnel.log"
# 与 "cloudflared-state/run.sh",裸 -f 云 'cloudflared.*tunnel' 会把这行命令行
# 误当成隧道进程 —— 于是永远显示"已在运行",而真正的隧道早挂了。按进程名精确匹配。
cf_alive() { pgrep -x cloudflared >/dev/null 2>&1; }

# 统一的拉起:flock -n 保证同一服务不会有两份 watchdog;.stop 是既有停止约定
launch() {  # $1=锁文件 $2=停止标记 $3=启动器 $4=日志
    rm -f "$2"
    nohup flock -n "$1" bash -c "
        while true; do
            [ -f '$2' ] && { echo \"[\$(date '+%F %T')] 检测到 .stop,watchdog 退出\" >> '$4'; break; }
            bash '$3' >> '$4' 2>&1
            echo \"[\$(date '+%F %T')] 进程退出,10 秒后重启\" >> '$4'
            sleep 10
        done
    " >/dev/null 2>&1 &
}

# ---------- 0. 环境盘点:先看清哪些东西在,避免后面报错时还要猜 ----------
echo "=== 容器环境盘点 ==="
for p in "$CPA_DIR" "$CC_DIR" "$BOT_DIR" "$CF_STATE"; do
    [ -d "$p" ] && echo "  ✅ $p" || echo "  ❌ $p 不存在"
done
[ -f "$CC_DIR/run.sh" ] && echo "  ✅ cc-connect 启动器" || echo "  ❌ cc-connect 启动器缺失(先跑 deploy-codex.sh)"
[ -f "$CC_DIR/bots.env" ] && echo "  ✅ bots.env" || echo "  ⚠️ bots.env 缺失(隧道若走 named 模式会退回 quick)"
echo

# 部署模式判定:cc-connect 用的 App 与自研 bot 是否同一个
# 同一个 → 复用模式,只能二选一;不同 → 新建机器人模式,两个都能跑
MODE=unknown
if [ -f "$CC_DIR/config.toml" ] && [ -f "$BOT_DIR/feishu-bot-config.json" ]; then
    CC_IDS=$(grep -oE 'cli_[A-Za-z0-9]+' "$CC_DIR/config.toml" 2>/dev/null | sort -u)
    BOT_ID=$(grep -oE 'cli_[A-Za-z0-9]+' "$BOT_DIR/feishu-bot-config.json" 2>/dev/null | sort -u | head -1)
    if [ -n "$BOT_ID" ] && echo "$CC_IDS" | grep -qx "$BOT_ID"; then
        MODE=reuse
    elif [ -n "$CC_IDS" ]; then
        MODE=new
    fi
fi
case "$MODE" in
    reuse) echo "  部署模式:复用模式 —— cc-connect 占用了自研 bot 的 App,本次不拉起自研 bot" ;;
    new)   echo "  部署模式:新建机器人模式 —— cc-connect 与自研 bot 各用各的 App,两者都拉起" ;;
    *)     echo "  ⚠️ 无法判定部署模式(缺 config.toml 或 bot 配置)—— 按最保守处理:不动自研 bot" ;;
esac
echo

# ---------- 1. CPA 本体(隧道依赖它,必须最先起来) ----------
echo "[1/5] CPA 本体(cli-proxy-api,端口 $CPA_PORT)..."
if cpa_alive; then
    echo "  ➖ 已在运行,跳过"
else
    if [ ! -d "$CPA_DIR" ]; then
        echo "  ❌ 目录不存在: $CPA_DIR"
    else
        # 平台或别的机制可能正在拉起它,给它一点时间再决定要不要自己动手,
        # 否则两边同时起会撞端口
        echo "  未见进程,等 15 秒确认不是别人正在拉起..."
        for _ in $(seq 1 5); do
            sleep 3
            cpa_alive && break
        done
        if cpa_alive; then
            echo "  ➖ 期间已被拉起,跳过"
        else
            # 优先用既有启动器;没有才生成一个 —— 生成物只写这一个文件,
            # 不碰 config.yaml 等既有配置
            CPA_RUN="$CPA_DIR/run.sh"
            if [ ! -f "$CPA_RUN" ]; then
                # 配置文件按实际存在的挑,挑不到就不传 --config(用程序内置默认)
                CPA_CFG=""
                for f in config.yaml config.yml config.json; do
                    [ -f "$CPA_DIR/$f" ] && { CPA_CFG="$f"; break; }
                done
                if [ -n "$CPA_CFG" ]; then
                    cat > "$CPA_RUN" <<EOF
#!/bin/bash
# cli-proxy-api 启动器 —— 由 restore-all.sh 生成
# 工作目录必须是 $CPA_DIR:配置里的相对路径(密钥文件、日志、数据目录)都相对它解析
cd "$CPA_DIR"
export HOME="\${HOME:-/root}"
exec "$CPA_DIR/cli-proxy-api" --config $CPA_CFG
EOF
                else
                    cat > "$CPA_RUN" <<EOF
#!/bin/bash
# cli-proxy-api 启动器 —— 由 restore-all.sh 生成
# 未找到 config.yaml/yml/json,故不传 --config,走程序内置默认配置
cd "$CPA_DIR"
export HOME="\${HOME:-/root}"
exec "$CPA_DIR/cli-proxy-api"
EOF
                fi
                chmod +x "$CPA_RUN"
                echo "  ✅ 已生成启动器 $CPA_RUN"
            else
                echo "  ✅ 复用既有启动器 $CPA_RUN"
            fi
            launch "$CPA_DIR/.watchdog.lock" "$CPA_DIR/.stop" "$CPA_RUN" "$CPA_DIR/cpa.log"
            # 等端口真的通,不是等进程出现 —— 进程在但配置错时端口照样不通
            for _ in $(seq 1 15); do
                sleep 2
                curl -s -o /dev/null -m 3 "http://127.0.0.1:$CPA_PORT/" && break
            done
            if curl -s -o /dev/null -m 3 "http://127.0.0.1:$CPA_PORT/" 2>/dev/null; then
                echo "  ✅ 已启动并响应(127.0.0.1:$CPA_PORT)"
            elif pgrep -x cli-proxy-api >/dev/null 2>&1; then
                echo "  ⚠️ 进程在跑但端口 $CPA_PORT 无响应,查 $CPA_DIR/cpa.log"
                echo "     端口不是 $CPA_PORT 就设 CPA_PORT 后重跑本脚本"
            else
                echo "  ❌ 未能启动,查 $CPA_DIR/cpa.log"
            fi
        fi
    fi
fi
echo

# ---------- 2. cc-connect(codex + claude 两个机器人) ----------
echo "[2/5] cc-connect(codex / claude 机器人)..."
if alive "/workspace/cc-connect/cc-connect"; then
    echo "  ➖ 已在运行,跳过"
elif [ ! -f "$CC_DIR/run.sh" ]; then
    echo "  ❌ 启动器缺失: $CC_DIR/run.sh"
    echo "     先跑一次部署脚本生成配置与启动器:bash $CC_DIR/deploy-codex.sh"
elif [ ! -f "$CC_DIR/config.toml" ]; then
    echo "  ❌ 配置缺失: $CC_DIR/config.toml(先跑 deploy-codex.sh)"
else
    launch "$CC_DIR/.watchdog.lock" "$CC_DIR/.stop" "$CC_DIR/run.sh" "$CC_DIR/cc.log"
    # 长连接建立需要时间,等进程稳住了再看日志,避免把"刚起还没连上"误判成失败
    for _ in $(seq 1 10); do
        sleep 3
        alive "/workspace/cc-connect/cc-connect" && break
    done
    if alive "/workspace/cc-connect/cc-connect"; then
        echo "  ✅ 已启动,最近日志:"
        tail -6 "$CC_DIR/cc.log" 2>/dev/null | sed 's/^/     /'
    else
        echo "  ❌ 未能启动,最近日志:"
        tail -20 "$CC_DIR/cc.log" 2>/dev/null | sed 's/^/     /'
    fi
fi
echo

# ---------- 3. 自研 bot(仅新建机器人模式下拉起) ----------
echo "[3/5] 自研 bot(feishu-bot)..."
if [ "$MODE" = "reuse" ]; then
    if alive "/workspace/cc-connect/cc-connect"; then
        echo "  ➖ 复用模式下它与 cc-connect 抢同一个 App 的长连接,按部署模式不拉起"
    else
        # 复用模式下 bot 与 cc-connect 是二选一:cc-connect 没起来又不拉 bot,
        # 等于飞书通道彻底断了 —— 这时必须回滚,不能只是"跳过"
        echo "  ⚠️ 复用模式且 cc-connect 未运行 —— 飞书通道现在是断的。"
        echo "     先回滚到自研 bot 恢复通道:bash $CC_DIR/rollback.sh"
    fi
elif alive "/workspace/feishu-bot/venv/bin/python"; then
    echo "  ➖ 已在运行,跳过"
elif [ ! -d "$BOT_DIR" ]; then
    echo "  ➖ 未安装过,跳过"
elif [ ! -f "$BOT_DIR/install.sh" ]; then
    echo "  ❌ 安装脚本缺失: $BOT_DIR/install.sh"
else
    # 直接调它自己的安装脚本:它建 venv、校验配置、拉 watchdog 一步做完,
    # 脚本头也明写"VM 休眠恢复/平台重建后需重新执行本脚本"。依赖已装时
    # pip 这一步很快,不另造一套启动逻辑。
    bash "$BOT_DIR/install.sh"
    for _ in $(seq 1 10); do
        sleep 3
        alive "/workspace/feishu-bot/venv/bin/python" && break
    done
    if alive "/workspace/feishu-bot/venv/bin/python"; then
        echo "  ✅ 已启动"
    else
        echo "  ⚠️ 未见进程,查 $BOT_DIR/bot.log"
    fi
fi
echo

# ---------- 4. CPA 隧道(依赖 [1/5] 的端口已通) ----------
echo "[4/5] CPA 隧道(cloudflared)..."
if cf_alive; then
    echo "  ➖ 已在运行,跳过"
elif [ ! -f "$CC_DIR/deploy-cpa-tunnel.sh" ]; then
    echo "  ➖ 未安装隧道脚本,跳过(不需要外网访问管理面板就无需它)"
else
    # 后台跑:它内部要等边缘连接注册(最多 60 秒)且可能要先下载二进制
    nohup bash "$CC_DIR/deploy-cpa-tunnel.sh" > "$CC_DIR/cpa-tunnel.log" 2>&1 < /dev/null &
    echo "  ⏳ 已在后台启动(最多等 60 秒建连,失败会自动从 QUIC 换 http2 重试)"
fi
echo

# ---------- 5. 汇总 ----------
echo "[5/5] 汇总"
echo "  ┌──────────────────┬──────────────────────────────────────────"
printf "  │ %-16s │ %s\n" "CPA 本体" "$(cpa_alive && echo "✅ 运行中  http://127.0.0.1:$CPA_PORT" || echo '➖ 未运行')"
printf "  │ %-16s │ %s\n" "cc-connect" "$(alive '/workspace/cc-connect/cc-connect' && echo '✅ 运行中(codex / claude)' || echo '➖ 未运行')"
case "$MODE" in
    reuse) printf "  │ %-16s │ %s\n" "自研 bot" "➖ 复用模式下按设计不拉起" ;;
    new)   printf "  │ %-16s │ %s\n" "自研 bot" "$(alive '/workspace/feishu-bot/venv/bin/python' && echo '✅ 运行中' || echo '➖ 未运行')" ;;
    *)     printf "  │ %-16s │ %s\n" "自研 bot" "➖ 模式未判定,未动它" ;;
esac
printf "  │ %-16s │ %s\n" "CPA 隧道" "$(cf_alive && echo '✅ 运行中' || echo '⏳ 未运行/仍在建连,见下方日志')"
echo "  └──────────────────┴──────────────────────────────────────────"
echo
echo "隧道地址(建连需要几十秒,稍后看):"
echo "  tail -30 $CC_DIR/cpa-tunnel.log"
echo "   · quick 模式:https://<随机>.trycloudflare.com/management.html —— 每次重启都换"
echo "   · named 模式:https://<你在 CF 配的子域>/management.html —— 固定"
echo
echo "重启后飞书机器人没反应时,先看对应日志:"
echo "  tail -30 $CC_DIR/cc.log            # codex / claude"
echo "  tail -30 $BOT_DIR/bot.log          # 自研 bot"
echo "  tail -30 $CPA_DIR/cpa.log          # CPA 本体"
echo "  tail -30 $CC_DIR/cpa-tunnel.log    # 隧道"
echo
echo "✅ 恢复流程执行完毕。"
