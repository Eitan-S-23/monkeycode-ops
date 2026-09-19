#!/bin/bash
# cc-connect + Codex 容器部署(MonkeyCode)
#
# 用法:先在 /workspace/cc-connect/bots.env 里写好下列各项,再执行
#     nohup bash deploy-codex.sh > deploy.log 2>&1 < /dev/null &
#   bots.env 内容(等号后直接写值,不要加行尾注释 —— 会被当成值的一部分):
#     # ── 飞书机器人凭证 ──
#     # CODEX_FEISHU_APP_ID/SECRET 留空则复用现有 bot 的 App(模式二)
#     CODEX_FEISHU_APP_ID=
#     CODEX_FEISHU_APP_SECRET=
#     # 下面两项可选,要挂 Claude Code 才填
#     CLAUDE_FEISHU_APP_ID=
#     CLAUDE_FEISHU_APP_SECRET=
#     # ── provider:地址与模型由使用者决定,脚本不设默认值,缺项直接报错 ──
#     # CODEX_BASE 形如 https://你的中转站/v1
#     CODEX_BASE=
#     CODEX_MODEL=
#     CODEX_KEY=
#     # 仅 Claude 需要
#     CLAUDE_BASE=
#     CLAUDE_MODEL=
#     CLAUDE_KEY=
#     # ── provider 名:可选,不填默认 main(纯标识符,不是地址) ──
#     # 见下方第 3 条说明;改了这里,配置里 options.provider 与 providers.name 同步改。
#     # CODEX_PROVIDER_NAME=main
#     # CLAUDE_PROVIDER_NAME=main
#     # ── 冒烟测试单独走哪条线:可选。默认就拿上面 CODEX_BASE/MODEL/KEY 去验; ──
#     # 想用另一条更便宜或更稳的线验"key 有效 / 网络通 / 模型名存在",填这三项。
#     # 只影响第 2 步的冒烟测试,不写进生成的 config.toml。
#     # CODEX_SMOKE_BASE=
#     # CODEX_SMOKE_MODEL=
#     # CODEX_SMOKE_KEY=
#     # ── 模型别名:可选,不填则 /model 里只有上面那个默认模型 ──
#     # 格式 模型名:别名,模型名:别名 ;别名可省略(只写模型名),也可整个省略该项。
#     # 别名是给 /model switch <别名> 用的短名,取值随意,只要求同一 provider 内不重复。
#     # CODEX_MODELS=gpt-5.3-codex:codex,gpt-5.4:gpt
#     # CLAUDE_MODELS=claude-opus-4-5:opus,claude-sonnet-4-5:sonnet
#     # ── 心跳:可选。session_key 必填才生效,且要等机器人真收到过消息才知道 ──
#     # 所以一般不在这里填,而是部署完用 set-heartbeat.py 自动发现后写入(见脚本尾部提示)。
#     # HEARTBEAT_INTERVAL_MINS=30
#     # HEARTBEAT_PROMPT=检查未完成的任务并继续
#   也可用同名环境变量直传(命令行优先于文件);但密钥走命令行会落进
#   shell 历史与 ps 输出,故推荐写文件。
#
# 两种模式,按是否提供 CODEX_FEISHU_APP_ID/SECRET 自动判定:
#
# 【模式一:新建机器人】推荐 —— 自研 bot 完全不动,零回归
#   飞书里多一个机器人跑 Codex;原 bot 继续管 status 卡片/保活/任意 shell 命令。
#   注意:新 App 里你的 open_id 与旧 App 不同,首次需发 /whoami 取回后填进配置。
#
# 【模式二:复用现有 bot 的 App】只有一个机器人,但自研 bot 必须让位
#   会停掉自研 bot 接管其长连接,并把它的两项平台能力(status/保活)摘成独立脚本继承。
#
# 追加 Claude Code(两种模式下都需要单独一个飞书 App:一个 App 的长连接只能挂一个 project)。
#
# 设计要点:
# 1) 同一飞书 App 同一时刻只能有一条长连接。模式二必须先停自研 bot,否则两边抢事件;
#    因此脚本在动 bot 之前先做 Codex 冒烟测试,provider 不通就直接退出,不触碰现有通道。
# 2) 模式二下自研 bot 身上两件"平台相关"的活没有替代品,摘成独立脚本随本次部署安装:
#    - status.py    :容器状态快照(原 status 卡片),由 AI 按 AGENTS.md 指引调用
#    - keepalive.py :驱动平台 opencode 对话保活,平台只认自己的 AI,codex/claude 不算
#    模式一不需要:原 bot 还在跑,自带这两项能力。
# 3) provider 地址与模型一律必填,脚本不做默认猜测 —— 猜错只会以"冒烟测试失败"
#    的形式暴露,排查成本远高于直接报错说清缺哪一项。
#    但 provider 的**名字**是例外:它是配置内的标识符,由
#    [[projects.agent.providers]] name 声明、[projects.agent.options] provider 引用,
#    两处必须一致(脚本自动保证),取值无对错,故默认 main 并开放
#    CODEX_PROVIDER_NAME / CLAUDE_PROVIDER_NAME 供改名(多个 provider 时靠名字区分)。
# 4) 容器无 systemd(cc-connect daemon 子命令依赖 systemd),复用 flock + 循环 watchdog。
# 5) 启动失败自动回滚,避免彻底失去飞书通道。

set -uo pipefail

CC_DIR=/workspace/cc-connect
BOT_DIR=/workspace/feishu-bot
LOG="$CC_DIR/cc.log"
NPM_BIN=/workspace/npm-global/bin

# 凭证从 bots.env 加载(推荐):避免密钥出现在命令行 —— 那会同时落进 shell
# 历史和 ps 输出。已由命令行显式传入的变量优先,不被文件覆盖。
ENV_FILE="$CC_DIR/bots.env"
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 容忍 Windows 端编辑留下的 CR,以及行首空白
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
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    echo "  ✅ 已从 $ENV_FILE 加载凭证"
fi

# provider 地址与模型名称一律由使用者在 bots.env 里指定,脚本不做任何默认猜测:
# 猜错只会以"冒烟测试失败"的形式暴露,排查成本远高于直接报错说清缺哪一项。
CODEX_KEY="${CODEX_KEY:-}"
CODEX_BASE="${CODEX_BASE:-}"
CODEX_MODEL="${CODEX_MODEL:-}"

# 冒烟测试单独走哪条线路:可选。默认验的就是 cc-connect 待会儿要用的那条
# (CODEX_BASE/MODEL/KEY);想拿另一条更便宜或更稳的线路来验"key 有效、网络通、
# 模型名存在",就给这三项。它们只影响冒烟测试,不影响生成的配置。
CODEX_SMOKE_BASE="${CODEX_SMOKE_BASE:-}"
CODEX_SMOKE_MODEL="${CODEX_SMOKE_MODEL:-}"
CODEX_SMOKE_KEY="${CODEX_SMOKE_KEY:-}"

CODEX_FEISHU_APP_ID="${CODEX_FEISHU_APP_ID:-}"
CODEX_FEISHU_APP_SECRET="${CODEX_FEISHU_APP_SECRET:-}"

CLAUDE_FEISHU_APP_ID="${CLAUDE_FEISHU_APP_ID:-}"
CLAUDE_FEISHU_APP_SECRET="${CLAUDE_FEISHU_APP_SECRET:-}"
CLAUDE_KEY="${CLAUDE_KEY:-}"
CLAUDE_BASE="${CLAUDE_BASE:-}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"

# provider 名在配置里只是个标识符:由 [[projects.agent.providers]] name 声明,
# 被 [projects.agent.options] provider 引用,两处必须一致(脚本自动保证)。
# 它不是网络参数、取值无对错,故给默认值 —— 与上面"必填无默认"的地址/模型不同。
# 想改名(例如以后挂多个 provider 靠名字区分)就设这两项。
CODEX_PROVIDER_NAME="${CODEX_PROVIDER_NAME:-main}"
CLAUDE_PROVIDER_NAME="${CLAUDE_PROVIDER_NAME:-main}"

# 模型别名:可选。值是 `模型名:别名` 的逗号分隔表,交给下面的 Python 生成器解析。
# 解析失败(空段、别名重复)会在生成阶段报错退出,不会静默丢弃 —— 别名写错只会在
# 用户 /model 时表现为"少了一项",那种故障很难回头定位。
CODEX_MODELS="${CODEX_MODELS:-}"
CLAUDE_MODELS="${CLAUDE_MODELS:-}"

# 心跳:session_key 是必填项,且必须等于机器人实际在用的会话键
# (形如 feishu:oc_xxx:ou_yyy),部署时通常还不知道,故默认留空不生成心跳段。
# 部署完成后用 set-heartbeat.py 自动发现并写入。
HEARTBEAT_SESSION_KEY="${HEARTBEAT_SESSION_KEY:-}"
HEARTBEAT_INTERVAL_MINS="${HEARTBEAT_INTERVAL_MINS:-}"
HEARTBEAT_PROMPT="${HEARTBEAT_PROMPT:-}"

# 模式判定:给了新 App 凭证就走"新建机器人",自研 bot 原样保留
if [ -n "$CODEX_FEISHU_APP_ID" ] && [ -n "$CODEX_FEISHU_APP_SECRET" ]; then
    MODE=new
else
    MODE=reuse
fi
export MODE

cd "$CC_DIR" 2>/dev/null || { echo "❌ 目录不存在: $CC_DIR"; exit 1; }

# 缺项即中止并指名要补哪一行,绝不静默套用默认值
require_var() {
    [ -n "${!1:-}" ] && return 0
    echo "❌ 缺少 $1 —— 请在 $ENV_FILE 里补一行: $1=..."
    exit 1
}
require_url() {
    require_var "$1"
    case "${!1}" in
        http://* | https://*) ;;
        *) echo "❌ $1 必须以 http:// 或 https:// 开头,当前值不是合法地址"; exit 1 ;;
    esac
}

# ---------- 1. 前置检查 ----------
echo "[1/6] 前置检查..."
require_var CODEX_KEY
require_url CODEX_BASE
require_var CODEX_MODEL
[ -x "$NPM_BIN/codex" ] || { echo "❌ 未找到 $NPM_BIN/codex"; exit 1; }
echo "  ✅ codex $("$NPM_BIN/codex" --version 2>&1 | head -1)"
echo "  ✅ Codex  provider: $CODEX_BASE   模型: $CODEX_MODEL"

# 给了 Claude 的 App 凭证就是明确要挂 Claude,配套项缺一不可 ——
# 不写成"缺任一项就静默跳过 Claude",那会让配置结果与预期不符却看不出原因
if [ -n "$CLAUDE_FEISHU_APP_ID" ] || [ -n "$CLAUDE_FEISHU_APP_SECRET" ]; then
    require_var CLAUDE_FEISHU_APP_ID
    require_var CLAUDE_FEISHU_APP_SECRET
    require_var CLAUDE_KEY
    require_url CLAUDE_BASE
    require_var CLAUDE_MODEL
    WANT_CLAUDE=1
    echo "  ✅ Claude provider: $CLAUDE_BASE   模型: $CLAUDE_MODEL"
else
    WANT_CLAUDE=0
fi
export WANT_CLAUDE

# claude 二进制同样必须在位:与上面的 codex 一样提前拦下,
# 否则要等到 claude project 真收到消息时才在运行期报错,排查更绕
if [ "$WANT_CLAUDE" = "1" ]; then
    [ -x "$NPM_BIN/claude" ] || {
        echo "❌ 未找到 $NPM_BIN/claude —— 先执行 npm i -g @anthropic-ai/claude-code"
        exit 1
    }
    echo "  ✅ claude $("$NPM_BIN/claude" --version 2>&1 | head -1)"
fi

if [ "$MODE" = new ]; then
    echo "  ✅ 模式:新建机器人(Codex App ${CODEX_FEISHU_APP_ID:0:12}…)—— 自研 bot 保持运行,不受影响"
else
    echo "  ⚠️ 模式:复用现有 bot 的 App —— 部署过程中会停掉自研 bot"
    echo "     若不希望停 bot,请另建一个飞书自建应用并用 CODEX_FEISHU_APP_ID/CODEX_FEISHU_APP_SECRET 传入"
fi

# ---------- 2. Codex 冒烟测试(动 bot 之前) ----------
# 用临时 CODEX_HOME 验证 provider 真能出话;失败则直接退出,自研 bot 不受影响。
SMOKE_BASE="${CODEX_SMOKE_BASE:-$CODEX_BASE}"
SMOKE_MODEL="${CODEX_SMOKE_MODEL:-$CODEX_MODEL}"
SMOKE_KEY="${CODEX_SMOKE_KEY:-$CODEX_KEY}"
echo "[2/6] Codex 冒烟测试(最长 180 秒)"
echo "      线路 $SMOKE_BASE / 模型 $SMOKE_MODEL$( [ -n "$CODEX_SMOKE_MODEL" ] && echo " (来自 CODEX_SMOKE_* 单独指定)" )"
SMOKE_HOME=/workspace/codex-home-smoke
rm -rf "$SMOKE_HOME" && mkdir -p "$SMOKE_HOME"
# wire_api 必须写 responses:codex 0.155 起已彻底移除 chat
# ("`wire_api = \"chat\"` is no longer supported",见 openai/codex#7782)。
# 中转站的 /v1/responses 实测可用,所以对 codex 这边只有 responses 一条路。
cat > "$SMOKE_HOME/config.toml" <<EOF
model = "$SMOKE_MODEL"
model_provider = "smoke"

[model_providers.smoke]
name = "smoke"
base_url = "$SMOKE_BASE"
env_key = "SMOKE_KEY"
wire_api = "responses"
EOF

SMOKE_OUT=$(cd /workspace && SMOKE_KEY="$SMOKE_KEY" CODEX_HOME="$SMOKE_HOME" \
    timeout 180 "$NPM_BIN/codex" exec --skip-git-repo-check "只回复两个字:OK" 2>&1 | tail -20)
echo "$SMOKE_OUT" | sed 's/^/    /'

# 判定要卡死在"模型真的回了一个独立的 OK"。旧版写的是 grep -qiE "OK|完成|success",
# 而 -i 让 "broken"(broken pipe)里的 ok 也算命中了 —— provider 半路断流时反而判通过,
# 部署照跑,最后以"机器人不回话"的形式在别处爆掉。\b 是词边界,只认独立的 OK。
#
# 光靠 OK 还不够:中转站报错时会把错误 JSON 打出来,里面完全可能夹一个独立的 ok
# (例如 {"code":0,"msg":"ok"} 之外的包装、或 "retry: ok" 之类的中间态)。所以再加一条
# 否决项 —— 出现下列字样一律判失败。这张表刻意只收**接口层错误**的措辞:codex 自己的
# 日志行长这样(ERROR module: message),不会被它们误伤,否则运行期一条无关告警
# 就能把好线路判死。
SMOKE_ERR_RE='"error"|new_api_error|invalid token|unauthorized|broken pipe|econnrefused|etimedout|connection refused'
if echo "$SMOKE_OUT" | grep -qiE '\bOK\b' && ! echo "$SMOKE_OUT" | grep -qiE "$SMOKE_ERR_RE"; then
    echo "  ✅ 冒烟测试通过"
else
    echo "  ❌ 冒烟测试未通过。"
    echo "     自研 bot 未受影响,飞书通道保持原样。"
    # 配置项与 codex 版本不兼容时,报错长得完全不像网络问题,却会被"密钥/网络/模型名"
    # 那句带偏 —— 现场就栽过:codex 0.155 拒收 wire_api=chat,真因是配置字段作废,
    # 排查方向却被指向中转站。这两类分开给提示。
    if echo "$SMOKE_OUT" | grep -qiE 'error loading config|no longer supported|unknown field|invalid type'; then
        echo "     排查方向:配置项与 codex 版本不兼容(不是网络问题);上面的报错会点名是哪个字段。"
    else
        echo "     排查方向:密钥是否有效 / base_url 是否可达 / 模型名 $SMOKE_MODEL 是否存在"
    fi
    exit 1
fi
rm -rf "$SMOKE_HOME"

# ---------- 3. 生成 config.toml ----------
echo "[3/6] 生成 cc-connect 配置..."
CODEX_KEY="$CODEX_KEY" CODEX_MODEL="$CODEX_MODEL" CODEX_BASE="$CODEX_BASE" \
CODEX_PROVIDER_NAME="$CODEX_PROVIDER_NAME" CODEX_MODELS="$CODEX_MODELS" \
CLAUDE_FEISHU_APP_ID="$CLAUDE_FEISHU_APP_ID" CLAUDE_FEISHU_APP_SECRET="$CLAUDE_FEISHU_APP_SECRET" \
CLAUDE_KEY="$CLAUDE_KEY" CLAUDE_BASE="$CLAUDE_BASE" CLAUDE_MODEL="$CLAUDE_MODEL" \
CLAUDE_PROVIDER_NAME="$CLAUDE_PROVIDER_NAME" CLAUDE_MODELS="$CLAUDE_MODELS" \
HEARTBEAT_SESSION_KEY="$HEARTBEAT_SESSION_KEY" \
HEARTBEAT_INTERVAL_MINS="$HEARTBEAT_INTERVAL_MINS" HEARTBEAT_PROMPT="$HEARTBEAT_PROMPT" \
PYTHONUTF8=1 python3 - <<'PYEOF' || exit 1
import json
import os
import pathlib

OUT = pathlib.Path("/workspace/cc-connect/config.toml")
BOT_CFG = pathlib.Path("/workspace/feishu-bot/feishu-bot-config.json")
env = os.environ
mode = env.get("MODE", "reuse")

# provider 名:纯标识符,script 里给默认值 main,可与 options.provider 双向改名,
# 只要两处一致即可 —— 下面统一由这两个变量插值,杜绝手改漏改。
cx_pname = (env.get("CODEX_PROVIDER_NAME") or "main").strip() or "main"
cl_pname = (env.get("CLAUDE_PROVIDER_NAME") or "main").strip() or "main"


def parse_models(raw, label):
    """把 `模型:别名,模型:别名` 解析成 [(模型, 别名)];别名可省略。

    别名重复必须拦下:它只在用户 /model switch 时才表现为"切错模型",
    那时早已离开部署现场,回头定位成本远高于现在直接报错。
    """
    out, seen = [], set()
    for item in (raw or "").split(","):
        item = item.strip()
        if not item:
            continue
        model, _, alias = item.partition(":")
        model, alias = model.strip(), alias.strip()
        if not model:
            raise SystemExit(f"❌ {label} 里有空模型名: {item!r}")
        if alias and alias in seen:
            raise SystemExit(f"❌ {label} 里别名重复: {alias!r} —— /model switch 会指代不清")
        if alias:
            seen.add(alias)
        out.append((model, alias))
    return out


def models_block(models, indent):
    """生成 [[projects.agent.providers.models]] 子表;别名缺省时只写 model 一行"""
    if not models:
        return ""
    pad = " " * indent
    parts = []
    for model, alias in models:
        lines = [f"{pad}[[projects.agent.providers.models]]", f'{pad}  model = "{model}"']
        if alias:
            lines.append(f'{pad}  alias = "{alias}"')
        parts.append("\n".join(lines))
    return "\n\n" + "\n\n".join(parts)


def heartbeat_block(session_key, interval, prompt, indent):
    """生成 [projects.heartbeat] 子表。

    session_key 为空则整段不生成 —— 它在 cc-connect 里是必填项,缺了只会被
    判为"未配置心跳"而静默不跑,留一段死配置反而让人以为心跳已开。
    """
    if not session_key:
        return ""
    pad = " " * indent
    lines = [
        f"{pad}[projects.heartbeat]",
        f"{pad}  enabled = true",
        f'{pad}  session_key = "{session_key}"',
    ]
    if interval:
        try:
            lines.append(f"{pad}  interval_mins = {int(interval)}")
        except ValueError:
            raise SystemExit(f"❌ HEARTBEAT_INTERVAL_MINS 不是整数: {interval!r}")
    if prompt:
        # 用 json.dumps 做转义:JSON 的基本字符串转义规则与 TOML 基本字符串兼容
        # (\" \\ \n 等写法一致),ensure_ascii=False 保留中文可读性。
        lines.append(f"{pad}  prompt = {json.dumps(prompt, ensure_ascii=False)}")
    return "\n\n" + "\n".join(lines)


cx_models = parse_models(env.get("CODEX_MODELS"), "CODEX_MODELS")
cl_models = parse_models(env.get("CLAUDE_MODELS"), "CLAUDE_MODELS")
# 心跳只给 Codex project 生成:一个 project 一个心跳,Claude 侧要开就跑一次
# set-heartbeat.py(它能各自独立发现会话键)。
hb_key = (env.get("HEARTBEAT_SESSION_KEY") or "").strip()
hb_txt = heartbeat_block(hb_key, env.get("HEARTBEAT_INTERVAL_MINS"),
                         env.get("HEARTBEAT_PROMPT"), 2)

if mode == "new":
    app_id = env.get("CODEX_FEISHU_APP_ID", "").strip()
    app_secret = env.get("CODEX_FEISHU_APP_SECRET", "").strip()
    # 飞书 open_id 按 App 隔离:新 App 里同一用户的 ID 与旧 App 不同,
    # 不能沿用旧 bot 配置里的值,留空待首次 /whoami 后回填。
    owner = env.get("OWNER_OPEN_ID", "").strip()
    if not app_id or not app_secret:
        raise SystemExit("❌ 新机器人模式缺少 CODEX_FEISHU_APP_ID / CODEX_FEISHU_APP_SECRET")
else:
    if not BOT_CFG.is_file():
        raise SystemExit(f"❌ 复用模式找不到现有 bot 配置: {BOT_CFG}")
    bot = json.loads(BOT_CFG.read_text(encoding="utf-8"))
    app_id = (bot.get("app_id") or "").strip()
    app_secret = (bot.get("app_secret") or "").strip()
    owner = (bot.get("owner_open_id") or "").strip()
    if not app_id or not app_secret or "请填入" in app_id + app_secret:
        raise SystemExit("❌ 现有 bot 配置里的 app_id/app_secret 不完整")
    if not owner:
        raise SystemExit("❌ owner_open_id 为空:请先在飞书给原 bot 发一条消息完成绑定再重跑")

# 已知 owner 才写白名单;留空时整条省略 —— cc-connect 未配置白名单即不设限,
# 首次上线正是靠这一步进到机器人里发 /whoami 拿到新 App 下的 open_id。
admin_line = f'admin_from = "{owner}"\n' if owner else ""
allow_line = f'      allow_from = "{owner}"\n' if owner else ""

blocks = [f'''data_dir = "/workspace/cc-connect/data"
''', f'''# Codex:密钥由 cc-connect 注入为 OPENAI_API_KEY 并写入 auth.json,
# 容器全局环境变量无需配置;codex_home 落 /workspace 保证重启 VM 后会话仍在。
[[projects]]
name = "codex"
{admin_line}
  [projects.agent]
    type = "codex"

    [projects.agent.options]
      work_dir = "/workspace"
      codex_home = "/workspace/codex-home"
      provider = "{cx_pname}"
      mode = "auto-edit"
      sandbox_mode = "workspace-write"
      approval_policy = "on-request"

    [[projects.agent.providers]]
      name = "{cx_pname}"
      api_key = "{env['CODEX_KEY']}"
      base_url = "{env['CODEX_BASE']}"
      model = "{env['CODEX_MODEL']}"{models_block(cx_models, 6)}

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "{app_id}"
      app_secret = "{app_secret}"
{allow_line}{hb_txt}''']

# Claude Code 需要独立的飞书 App:一个 App 的长连接只能被一个 project 占用。
# 是否启用由 WANT_CLAUDE 决定(bash 侧已校验配套项齐全),此处不再自行判断。
if env.get("WANT_CLAUDE") == "1":
    blocks.append(f'''# Claude Code:走 ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN(adapter 会清空 ANTHROPIC_API_KEY)。
# ANTHROPIC_DEFAULT_* 三个别名统一顶到同一个模型:上游若按模型计价,可避免
# Claude Code 内部挑 Haiku 之类的廉价调用落到意料外的模型上。
[[projects]]
name = "claude"
{admin_line}
  [projects.agent]
    type = "claudecode"

    [projects.agent.options]
      work_dir = "/workspace"
      mode = "default"
      provider = "{cl_pname}"

    [[projects.agent.providers]]
      name = "{cl_pname}"
      api_key = "{env['CLAUDE_KEY']}"
      base_url = "{env['CLAUDE_BASE']}"
      model = "{env['CLAUDE_MODEL']}"{models_block(cl_models, 6)}

      [projects.agent.providers.env]
        ANTHROPIC_DEFAULT_HAIKU_MODEL = "{env['CLAUDE_MODEL']}"
        ANTHROPIC_DEFAULT_OPUS_MODEL = "{env['CLAUDE_MODEL']}"
        ANTHROPIC_DEFAULT_SONNET_MODEL = "{env['CLAUDE_MODEL']}"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "{env['CLAUDE_FEISHU_APP_ID']}"
      app_secret = "{env['CLAUDE_FEISHU_APP_SECRET']}"
{allow_line}''')

text = "\n".join(blocks)

# 写盘前先回验:配置错一处 cc-connect 就起不来,而那时回滚脚本已经介入,
# 故障会以"机器人没反应"的形式出现,比在这里直接报错难查得多。
# tomllib 是 3.11+ 标准库;容器 python 更老时降级为结构性自检,不让整个部署挂掉。
try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None
    print("  ⚠️ python3 无 tomllib(需 3.11+),跳过 TOML 回验;"
          f"当前版本 {'.'.join(map(str, __import__('sys').version_info[:3]))}")

if tomllib is not None:
    doc = tomllib.loads(text)
    projs = {p.get("name"): p for p in doc.get("projects", [])}
    for want in ["codex"] + (["claude"] if env.get("WANT_CLAUDE") == "1" else []):
        if want not in projs:
            raise SystemExit(f"❌ 生成结果里缺少 project: {want}")
    # 别名回验:确认每条都真的落进了它所属的 provider,而不是被别的表头截断
    for pname, want_models in (("codex", cx_models), ("claude", cl_models)):
        if not want_models or pname not in projs:
            continue
        got = projs[pname]["agent"]["providers"][0].get("models", [])
        if len(got) != len(want_models):
            raise SystemExit(f"❌ {pname} 模型别名给了 {len(want_models)} 条,"
                             f"配置里只解析出 {len(got)} 条")
        for (model, alias), entry in zip(want_models, got):
            if entry.get("model") != model or (alias and entry.get("alias") != alias):
                raise SystemExit(f"❌ {pname} 模型别名错位: 期望 {model}/{alias},实得 {entry}")
    if hb_key:
        hb = projs["codex"].get("heartbeat") or {}
        if hb.get("session_key") != hb_key or hb.get("enabled") is not True:
            raise SystemExit(f"❌ 心跳段未正确写入: {hb}")

OUT.write_text(text, encoding="utf-8")
OUT.chmod(0o600)  # 含 provider 密钥,收紧读权限
names = [b.split('name = "')[1].split('"')[0] for b in blocks if '[[projects]]' in b]
print(f"  ✅ 已写入 {OUT}")
print(f"     飞书 App: {app_id[:12]}…")
print(f"     启用 project: {', '.join(names)}")
print(f"     provider 名: codex={cx_pname}" + (f", claude={cl_pname}" if env.get("WANT_CLAUDE") == "1" else ""))
if cx_models or cl_models:
    print(f"     模型别名: codex {len(cx_models)} 条" +
          (f", claude {len(cl_models)} 条" if env.get("WANT_CLAUDE") == "1" else ""))
if hb_key:
    print(f"     心跳: 已启用(session_key {hb_key[:24]}…)")
if "claude" not in names:
    print("     (未提供 CLAUDE_FEISHU_APP_ID/SECRET,本次只配 Codex)")
if owner:
    print(f"     白名单 owner: {owner[:12]}…")
else:
    print("     ⚠️ 尚未设置白名单:机器人启动后先在飞书发 /whoami 取回 open_id 再回填")
PYEOF

# ---------- 4. 安装摘出来的平台能力(status / 保活) ----------
# 仅复用模式需要:自研 bot 停用后这两件事没有替代品,必须独立存活。
#   status.py    原 status 卡片,改为脚本;AGENTS.md 指引 AI 在用户问状态时调用
#   keepalive.py 平台只认自己 opencode 的对话,codex/claude 的活动不计入回收判定
# 新建机器人模式下原 bot 仍在跑,自带这两项能力,不装也不碰。
if [ "$MODE" = "reuse" ]; then
echo "[4/6] 安装 status.py / keepalive.py / AGENTS.md..."

cat > "$BOT_DIR/status.py" <<'STATUSEOF'
#!/usr/bin/env python3
"""容器状态快照(原自研 bot 的 status 卡片能力,改为独立脚本)。

供飞书里的 AI agent 调用:用户问容器状态/内存/磁盘时执行本脚本再转述。

内存口径:平台按需供页,静态"已用"含预留映射(虚高),MemAvailable 抖动大;
实测持续分配到约 7.4G 才触发 OOM,故以 进程(AnonPages) + 内核可回收缓存
作为真实占用,并以 7.4G 作为可用预算。
"""
import os
import time
from pathlib import Path


def _meminfo(key):
    """读 /proc/meminfo 单项,返回 kB;失败返回 None"""
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            name, _, rest = line.partition(":")
            if name.strip() == key:
                return int(rest.strip().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    return None


def _first_number(path):
    try:
        return float(Path(path).read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def format_duration(seconds):
    if seconds is None or seconds < 0:
        return "未知"
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    parts = []
    if days:
        parts.append(f"{days} 天")
    if hours:
        parts.append(f"{hours} 小时")
    parts.append(f"{minutes} 分钟")
    return " ".join(parts)


def format_size(num):
    if num is None:
        return "未知"
    value = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} B" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024


def disk_usage(path):
    try:
        stat = os.statvfs(path)
        total = stat.f_blocks * stat.f_frsize
        avail = stat.f_bavail * stat.f_frsize
        return total - avail, total
    except (AttributeError, OSError):
        return None, None  # 非 Linux 环境无 statvfs,跳过该行


def find_process(keyword):
    """在 /proc 里找 cmdline 含 keyword 的进程,返回 PID"""
    try:
        entries = list(Path("/proc").iterdir())
    except OSError:
        return None  # 非 Linux 环境(本地自测)无 /proc,直接判为未运行
    for entry in entries:
        if not entry.name.isdigit() or entry.name == str(os.getpid()):
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes().replace(b"\x00", b" ").decode(errors="ignore")
        except OSError:
            continue
        if keyword in cmdline:
            return entry.name
    return None


def snapshot():
    """返回状态行列表,便于被 import 复用或直接打印"""
    lines = [f"容器状态快照 {time.strftime('%F %T')}", ""]
    lines.append(f"运行时间: {format_duration(_first_number('/proc/uptime'))}")
    try:
        lines.append(f"CPU: {os.sysconf('SC_NPROCESSORS_ONLN')} 核")
    except (AttributeError, OSError, ValueError):
        lines.append("CPU: 未知")

    anon = _meminfo("AnonPages")
    if anon is not None:
        cached = (_meminfo("Cached") or 0) + (_meminfo("Buffers") or 0) \
            + (_meminfo("SReclaimable") or 0)
        used_gb = (anon + cached) / 1024 / 1024
        total = _meminfo("MemTotal")
        lines.append(f"内存: 进程 {format_size(anon * 1024)} + 内核/缓存 {format_size(cached * 1024)}")
        lines.append(
            f"      总量 {format_size(total * 1024) if total else '未知'},"
            f"余量约 {max(0.0, 7.4 - used_gb):.1f} GB(按实测 7.4G 预算)"
        )
    else:
        lines.append("内存: 读取失败")

    for label in ("/workspace", "/"):
        used, total = disk_usage(label)
        if total:
            lines.append(f"磁盘 {label}: {format_size(used)} / {format_size(total)}({used * 100 / total:.0f}%)")

    agent_pid = find_process("/app/agent/bin/agent")
    lines.append(f"平台 agent: {'✅ 运行中 (PID ' + agent_pid + ')' if agent_pid else '❌ 未运行'}")
    oc_pid = find_process("opencode")
    lines.append(f"opencode: {'✅ 运行中 (PID ' + oc_pid + ')' if oc_pid else '➖ 未运行'}")
    cc_pid = find_process("/workspace/cc-connect/cc-connect")
    lines.append(f"cc-connect: {'✅ 运行中 (PID ' + cc_pid + ')' if cc_pid else '➖ 未运行'}")
    ka_pid = find_process("python3 /workspace/feishu-bot/keepalive.py")
    lines.append(f"保活进程: {'✅ 运行中 (PID ' + ka_pid + ')' if ka_pid else '❌ 未运行'}")
    return lines


if __name__ == "__main__":
    print("\n".join(snapshot()))
STATUSEOF
chmod +x "$BOT_DIR/status.py"

cat > "$BOT_DIR/keepalive.py" <<'KEEPEOF'
#!/usr/bin/env python3
"""对话保活:定期驱动平台 opencode 发起一轮真实 AI 对话。

平台按 task.LastActiveAt 判定环境空闲并回收;容器内 shell 活动不计入。
必须经由**平台自己的 AI**(opencode 本地 API 127.0.0.1:4096)对话才算数 ——
cc-connect 里 codex/claude 的对话平台不认,不能替代本脚本。

同时每 5 分钟写一次活动戳(轻量,对"空闲检测"型环境有效)。

用法: nohup python3 keepalive.py >> keepalive.log 2>&1 &
"""
import json
import time
import urllib.request
from pathlib import Path

OPENCODE_BASE = "http://127.0.0.1:4096"
CHAT_INTERVAL = 12 * 3600  # 秒:3 天回收窗口内留足裕量
STAMP_INTERVAL = 300
STAMP = Path("/workspace/.feishu-bot-keepalive")


def _oc(method, path, body=None, timeout=90):
    """调 opencode 本地 API,返回解析后的 JSON"""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        OPENCODE_BASE + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        text = resp.read().decode()
    return json.loads(text) if text.strip() else None


def chat_once():
    """建会话 → 发 hi → 删会话,返回耗时秒"""
    started = time.monotonic()
    session_id = _oc("POST", "/session", {})["id"]
    try:
        _oc(
            "POST", f"/session/{session_id}/message",
            {"parts": [{"type": "text", "text": "hi"}]},
        )
    finally:
        try:
            _oc("DELETE", f"/session/{session_id}")
        except Exception:
            pass  # 清理失败不影响保活结果
    return time.monotonic() - started


def main():
    next_chat = 0.0  # 启动后先跑一轮,立即验证闭环
    while True:
        try:
            STAMP.write_text(f"{int(time.time())}\n", encoding="utf-8")
        except OSError as error:
            print(f"[{time.strftime('%F %T')}] 写活动戳失败: {error!r}", flush=True)
        now = time.monotonic()
        if now >= next_chat:
            try:
                elapsed = chat_once()
                print(f"[{time.strftime('%F %T')}] 对话保活成功,耗时 {elapsed:.0f}s", flush=True)
            except Exception as error:
                print(f"[{time.strftime('%F %T')}] 对话保活失败: {error!r}", flush=True)
            next_chat = now + CHAT_INTERVAL
        time.sleep(STAMP_INTERVAL)


if __name__ == "__main__":
    main()
KEEPEOF
chmod +x "$BOT_DIR/keepalive.py"

# AGENTS.md:Codex 默认会读工作区根目录的 AGENTS.md,借此把 status 脚本接回去
if [ ! -f /workspace/AGENTS.md ]; then
    cat > /workspace/AGENTS.md <<'AGENTSEOF'
# 容器工作约定

本目录(/workspace)是 MonkeyCode 云容器的工作区,通过飞书聊天远程驱动。
容器内的 shell 环境为 Debian,无 systemd/cron,常驻进程靠自己写的循环 watchdog 维持。

## 容器状态查询

用户询问容器状态、内存、磁盘、运行时长、进程是否存活时,**执行**
`python3 /workspace/feishu-bot/status.py` 并转述其输出,不要凭猜测作答。

## 保活

`/workspace/feishu-bot/keepalive.py` 负责驱动平台 opencode 对话以刷新任务活跃时间。
若用户问"保活还在不在",执行 status.py 看"保活进程"一行即可。
AGENTSEOF
    echo "  ✅ 已写入 /workspace/AGENTS.md"
else
    echo "  ➖ /workspace/AGENTS.md 已存在,保持原样(如需接入 status.py 请手工补充)"
fi
echo "  ✅ status.py / keepalive.py 就位"
else
echo "[4/6] 新建机器人模式:自研 bot 保持运行,跳过 status/保活 安装"
fi

# ---------- 5. 启动器 + watchdog(cc-connect 与保活各一个) ----------
echo "[5/6] 写入启动器与 watchdog..."
cat > "$CC_DIR/run.sh" <<'RUNEOF'
#!/bin/bash
# cc-connect 启动器:挂上 npm 全局 bin 以便找到 codex / claude
export PATH="/workspace/npm-global/bin:/usr/local/bin:$PATH"
export HOME="${HOME:-/root}"
mkdir -p /workspace/codex-home
cd /workspace/cc-connect
exec /workspace/cc-connect/cc-connect --config /workspace/cc-connect/config.toml
RUNEOF
chmod +x "$CC_DIR/run.sh"

rm -f "$CC_DIR/.stop"
nohup flock -n "$CC_DIR/.watchdog.lock" bash -c "
    while true; do
        [ -f '$CC_DIR/.stop' ] && { echo \"[\$(date '+%F %T')] 检测到 .stop,watchdog 退出\"; break; }
        bash '$CC_DIR/run.sh' >> '$LOG' 2>&1
        echo \"[\$(date '+%F %T')] cc-connect 退出,10 秒后重启\" >> '$LOG'
        sleep 10
    done
" >/dev/null 2>&1 &

# 保活独立 watchdog:与 cc-connect 同生共死,回滚时一并由 .stop 停掉。
# 仅复用模式需要 —— 新建机器人模式下原 bot 自带保活循环,重复启动会双跑 opencode 对话。
if [ "$MODE" = "reuse" ]; then
nohup flock -n "$CC_DIR/.keepalive.lock" bash -c "
    while true; do
        [ -f '$CC_DIR/.stop' ] && break
        python3 '$BOT_DIR/keepalive.py' >> '$BOT_DIR/keepalive.log' 2>&1
        echo \"[\$(date '+%F %T')] 保活进程退出,10 秒后重启\" >> '$BOT_DIR/keepalive.log'
        sleep 10
    done
" >/dev/null 2>&1 &
echo "  ✅ 两个 watchdog 已启动(cc-connect + 保活)"
else
echo "  ✅ cc-connect watchdog 已启动(保活由原 bot 自带,不重复启动)"
fi

# ---------- 6. 停自研 bot,交接飞书长连接(仅复用模式) ----------
if [ "$MODE" = "reuse" ]; then
echo "[6/6] 停止自研 bot 并接管飞书长连接..."
touch "$BOT_DIR/.stop"
pkill -f '^/workspace/feishu-bot/venv/bin/python' 2>/dev/null || true
sleep 3
if pgrep -f '^/workspace/feishu-bot/venv/bin/python' >/dev/null; then
    echo "  ⚠️ bot 仍在,强制结束"
    pkill -9 -f '^/workspace/feishu-bot/venv/bin/python' 2>/dev/null || true
    sleep 2
fi
echo "  ✅ bot 已停止(回滚:bash $CC_DIR/rollback.sh)"
else
echo "[6/6] 新建机器人模式:自研 bot 未受任何影响,继续在原 App 上服务"
fi

echo "等待 cc-connect 建立长连接(20 秒)..."
sleep 20

if pgrep -f '^/workspace/cc-connect/cc-connect' >/dev/null; then
    echo "  ✅ cc-connect 进程运行中"
    echo
    echo "=== 最近日志 ==="
    tail -15 "$LOG" 2>/dev/null || echo "(暂无日志)"
    echo "================"
    echo
    if [ "$MODE" = "reuse" ]; then
        echo "--- 保活进程 ---"
        # 模式串含 python3 前缀:watchdog 的 bash -c 里该路径带引号,不会误命中
        pgrep -f 'python3 /workspace/feishu-bot/keepalive\.py' >/dev/null \
            && echo "  ✅ 保活运行中(原 bot 已停,由它接管)" \
            || echo "  ⚠️ 保活未起来,查 $BOT_DIR/keepalive.log"
        echo
        echo "✅ 部署完成。去飞书给机器人发消息(原 bot 那个机器人,现在是 Codex 在应答)。"
    else
        echo "--- 自研 bot ---"
        if pgrep -f '^/workspace/feishu-bot/venv/bin/python' >/dev/null; then
            echo "  ✅ 原 bot 仍在运行,status / 保活 / shell 命令照旧"
        else
            echo "  ⚠️ 原 bot 未运行(本次未动它,检查 $BOT_DIR/bot.log)"
        fi
        echo
        echo "✅ 部署完成。去飞书会给【新机器人】发 /whoami,把返回的 open_id 填进"
        echo "   $CC_DIR/config.toml 的 admin_from 与 allow_from,再执行:"
        echo "   pkill -f '^/workspace/cc-connect/cc-connect'  # watchdog 10 秒内自动拉起"
    fi
    # 心跳的会话键必须等机器人真收到过消息才知道,故留到部署之后单独一步
    echo
    echo "--- 心跳(可选)---"
    echo "   先给机器人随便发一条消息,再执行:"
    echo "   python3 $CC_DIR/set-heartbeat.py            # 只列出已发现的会话键,不改配置"
    echo "   python3 $CC_DIR/set-heartbeat.py codex      # 给 codex 启用,键自动发现"
    echo
    echo "   无响应则回滚:bash $CC_DIR/rollback.sh"
else
    echo "  ❌ cc-connect 未能启动,最近日志:"
    tail -30 "$LOG" 2>/dev/null || echo "(无日志)"
    echo
    if [ "$MODE" = "reuse" ]; then
        echo "正在回滚到自研 bot..."
    else
        echo "正在回滚(新建机器人模式:只需停掉 cc-connect,原 bot 未被动过)..."
    fi
    bash "$CC_DIR/rollback.sh"
    exit 1
fi
