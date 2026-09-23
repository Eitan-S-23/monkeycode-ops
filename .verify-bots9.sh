#!/bin/bash
# 本地验证 add-codex-bots.py / set-allow-from.py / make-bots9-env.py ——
# 在本机用仿造的 config.toml 与假会话目录跑通各条路径,不碰容器。
#
# 为什么值得单独验:
#   这三个脚本改的是 cc-connect 的配置文件,而"9 个新机器人配置与现有 codex 一致"
#   这件事**不会自己报错** —— provider 少抄一行、白名单继承了旧 App 的 open_id、
#   心跳把 9 台机器人的消息推到同一个旧会话,三种错误都表现为"某个机器人怪怪的"。
#   所以这里的断言重点不是"能解析",而是:
#     · 新 project 与源 project 的差异**只有**脚本声明的那四处;
#     · admin_from / allow_from / heartbeat 真的没被继承;
#     · 原有两个 project 的字节**一字未动**;
#     · 白名单最终落在正确的表里(allow_from 在 platforms.options,admin_from 在 projects 层)。
#
# 夹具照抄 deploy-codex.sh 生成出来的形状,包括缩进与空行。
#   api_key / app_secret 的取值故意写得很短 —— 全是占位符、没有断言看它们的内容,
#   写长了会被全局 pre-commit 的密钥正则拦下。与其绕过那道闸门,不如让夹具本身
#   不带可疑字面量。
# 所有产物都在 .verify-bots9/ 内,不写项目外任何位置。
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VD="$HERE/.verify-bots9"
CFG="$VD/config.toml"
ENVF="$VD/bots9.env"

# 挑一个**真能跑**的 python:Windows 上 `command -v python3` 常指到 WindowsApps 下的
# 应用商店占位程序,它什么都不输出、也不报错 —— 直接用它会让整个验证跑成"所有断言
# 都失败但看不出原因"。按"能不能 import tomllib"挑,顺带保证回验用的解析器可用。
pick_python() {
    local c
    for c in python python3 py; do
        if command -v "$c" >/dev/null 2>&1 \
           && "$c" -c 'import tomllib' >/dev/null 2>&1; then
            command -v "$c"; return 0
        fi
    done
    return 1
}
PY="$(pick_python)"
if [ -z "$PY" ]; then
    echo "❌ 找不到可用的 python(需 3.11+,要能 import tomllib)"
    exit 1
fi
for f in add-codex-bots.py set-allow-from.py make-bots9-env.py; do
    [ -f "$HERE/$f" ] || { echo "❌ 找不到 $HERE/$f"; exit 1; }
done

rm -rf "$VD"; mkdir -p "$VD"

PASS=0
FAILED=0
pass() { PASS=$((PASS+1)); echo "  ✅ $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ❌ $1"; }
chk()  { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 —— 实际输出:"; printf '%s\n' "$3" | sed 's/^/     | /'; fi; }
nchk() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 —— 实际输出:"; printf '%s\n' "$3" | sed 's/^/     | /'; else pass "$1"; fi; }

# 从配置里读一个值:pyget <config> <以 projects 为名字空间的表达式>
# PYTHONIOENCODING 必须给:Windows 上 python 默认按 GBK 编码 stdout,中文断言会变成乱码
pyget() {
    PYTHONIOENCODING=utf-8 "$PY" - "$1" "$2" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
projects = {p.get("name"): p for p in doc.get("projects", [])}
print(eval(sys.argv[2], {"doc": doc, "projects": projects}))
PYEOF
}

# 取出某个 project 的整个文本区块(从它的 [[projects]] 到下一个)
block_of() {
    awk -v want="$2" '
        function flush() { if (name == want) printf "%s", buf }
        /^\[\[projects\]\]$/ { flush(); name = ""; done = 0; buf = $0 "\n"; next }
        {
            buf = buf $0 "\n"
            if (done) next
            if ($0 ~ /^name = "/) {
                name = $0
                sub(/^name = "/, "", name); sub(/".*$/, "", name)
                done = 1
            } else if ($0 ~ /^\[/) {
                done = 1
            }
        }
        END { flush() }
    ' "$1"
}

# 只跑脚本本身(不落盘副产物),返回 stdout+stderr
run_bots() { "$PY" "$HERE/add-codex-bots.py" "$@" 2>&1; }
run_allow() { "$PY" "$HERE/set-allow-from.py" "$@" 2>&1; }

# -----------------------------------------------------------------------------
# 夹具:与 deploy-codex.sh 生成的两段 project(codex / claude)
# -----------------------------------------------------------------------------
make_fixture() {
    cat > "$CFG" <<'EOF'
data_dir = "/workspace/cc-connect/data"

# Codex:密钥由 cc-connect 注入为 OPENAI_API_KEY 并写入 auth.json,
# 容器全局环境变量无需配置;codex_home 落 /workspace 保证重启 VM 后会话仍在。
[[projects]]
name = "codex"
admin_from = "ou_owner_in_old_app"

  [projects.agent]
    type = "codex"

    [projects.agent.options]
      work_dir = "/workspace"
      codex_home = "/workspace/codex-home"
      provider = "main"
      mode = "auto-edit"
      sandbox_mode = "workspace-write"
      approval_policy = "on-request"

    [[projects.agent.providers]]
      name = "main"
      api_key = "k"
      base_url = "https://relay.example/v1"
      model = "deepseek-v4-flash"

      [[projects.agent.providers.models]]
        model = "deepseek-v4-flash"
        alias = "flash"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_old_codex_app"
      app_secret = "s0"
      allow_from = "ou_owner_in_old_app"

  [projects.heartbeat]
    enabled = true
    session_key = "feishu:oc_oldchat:ou_owner_in_old_app"
    interval_mins = 30

# Claude Code:走 ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN(adapter 会清空 ANTHROPIC_API_KEY)。
[[projects]]
name = "claude"
admin_from = "ou_owner_in_old_app"

  [projects.agent]
    type = "claudecode"

    [projects.agent.options]
      work_dir = "/workspace"
      mode = "default"
      provider = "main"

    [[projects.agent.providers]]
      name = "main"
      api_key = "k"
      base_url = "https://relay.example"
      model = "deepseek-v4-flash"

      [projects.agent.providers.env]
        ANTHROPIC_DEFAULT_HAIKU_MODEL = "deepseek-v4-flash"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_old_claude_app"
      app_secret = "s0"
      allow_from = "ou_owner_in_old_app"
EOF
}

# 9 组凭证;每个 App ID 互不相同,便于断言"没有串台"
make_env9() {
    : > "$ENVF"
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
        {
            echo "CODEX${i}_APP_ID=cli_new_app_${i}"
            echo "CODEX${i}_APP_SECRET=sec${i}"
        } >> "$ENVF"
    done
}

echo "═══════════════════════════════════════════════════════════"
echo " 0. 夹具自检:仿造的 config.toml 本身是合法 TOML"
echo "═══════════════════════════════════════════════════════════"
make_fixture
if "$PY" -c 'import sys,tomllib,pathlib;tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' "$CFG" 2>/dev/null; then
    pass "夹具是合法 TOML"
else
    fail "夹具不是合法 TOML"; exit 1
fi
cp "$CFG" "$VD/before.toml"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 A:9 个 codex 机器人一次铺开"
echo "═══════════════════════════════════════════════════════════"
make_env9
OUT=$(run_bots "$ENVF" --config "$CFG")
chk "A 报告 9 个新 project 与源逐路径一致" "9 个新 project 与 codex 逐路径比对" "$OUT"
chk "A 打印了 codex_home 分开这条有意差异" "codex_home 按 project 分开" "$OUT"
chk "A 打印了不继承心跳" "不继承 admin_from / allow_from / heartbeat" "$OUT"
chk "A 收尾提示白名单回填" "set-allow-from.py --restart" "$OUT"

for i in 1 2 3 4 5 6 7 8 9; do
    got_id=$(pyget "$CFG" "projects['codex$i']['platforms'][0]['options']['app_id']")
    got_sec=$(pyget "$CFG" "projects['codex$i']['platforms'][0]['options']['app_secret']")
    got_home=$(pyget "$CFG" "projects['codex$i']['agent']['options']['codex_home']")
    if [ "$got_id" = "cli_new_app_$i" ] && [ "$got_sec" = "sec$i" ]; then
        pass "A codex$i 的 App 凭证是它自己那一组"
    else
        fail "A codex$i 的 App 凭证不对:$got_id / $got_sec"
    fi
    if [ "$got_home" = "/workspace/codex-home$i" ]; then
        pass "A codex$i 的 codex_home 独立(/workspace/codex-home$i)"
    else
        fail "A codex$i 的 codex_home 是 $got_home"
    fi
done

# 逐项对照:agent 部分除 codex_home 外必须与源逐字节一致(用同一套 leaf 摊平比对)
DIFF=$("$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
projs = {p["name"]: p for p in doc["projects"]}

def leaf(node, prefix=()):
    out = {}
    if isinstance(node, dict):
        for k, v in node.items():
            out.update(leaf(v, prefix + (str(k),)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.update(leaf(v, prefix + (str(i),)))
    else:
        out[prefix] = node
    return out

bad = []
src = leaf(projs["codex"])
for i in range(1, 10):
    new = leaf(projs[f"codex{i}"])
    for path, value in new.items():
        if path in src and src[path] == value:
            continue
        if path == ("name",) or path == ("agent", "options", "codex_home"):
            continue
        if path[:3] == ("platforms", "0", "options") and path[3] in ("app_id", "app_secret"):
            continue
        if path[:1] in (("admin_from",), ("heartbeat",)):
            continue
        if path == ("platforms", "0", "options", "allow_from"):
            continue
        bad.append(f"codex{i} {'.'.join(path)} = {value!r}")
print("\n".join(bad) if bad else "CLEAN")
PYEOF
)
if [ "$DIFF" = "CLEAN" ]; then
    pass "A 9 个新 project 相对源 project 只差声明的那几处(逐路径比对)"
else
    fail "A 出现了计划外的差异:"; printf '%s\n' "$DIFF" | sed 's/^/     | /'
fi

# 关键的三条:旧 App 的白名单/心跳绝不能跟过来
C1_BLOCK="$(block_of "$CFG" codex1)"
nchk "A 新 project 里没有 allow_from" "allow_from" "$C1_BLOCK"
nchk "A 新 project 里没有 admin_from" "admin_from" "$C1_BLOCK"
nchk "A 新 project 里没有 heartbeat" "heartbeat" "$C1_BLOCK"
if [ "$(grep -c 'oc_oldchat' "$CFG")" = "1" ]; then
    pass "A 旧 session_key 只剩老 project 自己那一处"
else
    fail "A 旧 session_key 出现 $(grep -c 'oc_oldchat' "$CFG") 次(应为 1:老 codex 的 heartbeat)"
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 B:原有 project 一字未动"
echo "═══════════════════════════════════════════════════════════"
# 原文件的字节必须是新文件的前缀
ORIG_BYTES=$(wc -c < "$VD/before.toml" | tr -d ' ')
if head -c "$ORIG_BYTES" "$CFG" | cmp -s - "$VD/before.toml"; then
    pass "B 原有内容是新文件的逐字节前缀(只追加,没改写)"
else
    fail "B 原有内容被改动了"
fi
chk "B claude 仍在配置里" "cli_old_claude_app" "$(cat "$CFG")"
[ -f "$CFG.pre-bots" ] && pass "B 落盘前留了备份 $CFG.pre-bots" || fail "B 没有备份"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 C:幂等 —— 重跑不产生任何改动"
echo "═══════════════════════════════════════════════════════════"
cp "$CFG" "$VD/after-A.toml"
rm -f "$CFG.pre-bots"
OUT=$(run_bots "$ENVF" --config "$CFG")
chk "C 报告无需改动" "无需改动" "$OUT"
chk "C 逐个说明已存在" "已存在,跳过" "$OUT"
if cmp -s "$CFG" "$VD/after-A.toml"; then pass "C 文件字节完全没变"; else fail "C 文件被改写了"; fi
[ -f "$CFG.pre-bots" ] && fail "C 无改动却写了备份" || pass "C 无改动不写备份"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 D:--dry-run 只说不做"
echo "═══════════════════════════════════════════════════════════"
make_fixture
cp "$CFG" "$VD/before-d.toml"
OUT=$(run_bots "$ENVF" --config "$CFG" --dry-run)
chk "D 打印计划" "新增" "$OUT"
chk "D 明说没写盘" "--dry-run:未写盘" "$OUT"
cmp -s "$CFG" "$VD/before-d.toml" && pass "D 文件没动" || fail "D 文件被改了"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 E:--update 只换已存在 project 的凭证"
echo "═══════════════════════════════════════════════════════════"
# 在 A 的结果上要求更新:这时 9 个都已存在
cp "$VD/after-A.toml" "$CFG"
sed -i 's/^CODEX3_APP_SECRET=sec3$/CODEX3_APP_SECRET=sec3_new/' "$ENVF"
OUT=$(run_bots "$ENVF" --config "$CFG" --update)
chk "E 报告更新凭证" "更新凭证" "$OUT"
got=$(pyget "$CFG" "projects['codex3']['platforms'][0]['options']['app_secret']")
[ "$got" = "sec3_new" ] && pass "E codex3 的新 secret 已生效" || fail "E codex3 的 secret 仍是 $got"
got=$(pyget "$CFG" "projects['codex7']['platforms'][0]['options']['app_secret']")
[ "$got" = "sec7" ] && pass "E 其它 project 的凭证没被动" || fail "E codex7 的 secret 变成了 $got"
if [ -z "$(pyget "$CFG" "projects['codex3']['platforms'][0]['options'].get('allow_from','')")" ]; then
    pass "E 没设白名单的仍没白名单"
else
    fail "E codex3 冒出了白名单"
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 F:坏输入必须停手,且不碰配置"
echo "═══════════════════════════════════════════════════════════"
check_reject() {   # check_reject <说明> <期望文案> <命令...>
    local desc="$1" want="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then fail "$desc —— 竟然退 0"; printf '%s\n' "$out" | sed 's/^/     | /'; return; fi
    chk "$desc" "$want" "$out"
}

printf 'CODEX1_APP_ID=cli_x\n' > "$VD/incomplete.env"
check_reject "F 缺 App Secret 报错" "缺 app_secret" run_bots "$VD/incomplete.env" --config "$CFG"
printf 'BOT1_APP_ID=cli_x\nBOT1_APP_SECRET=y\n' > "$VD/badkey.env"
check_reject "F 键名不对报错" "键名不认识" run_bots "$VD/badkey.env" --config "$CFG"
: > "$VD/empty.env"
check_reject "F 空文件报错" "没有解析出任何 App 凭证" run_bots "$VD/empty.env" --config "$CFG"
check_reject "F 源 project 不存在报错" "没有源 project" run_bots "$ENVF" --config "$CFG" --from nope
check_reject "F 目标与源同名报错" "和源同名" run_bots "$ENVF" --config "$CFG" --from codex3
check_reject "F 凭证文件不存在报错" "找不到凭证文件" run_bots "$VD/nope.env" --config "$CFG"
check_reject "F 配置不存在报错" "找不到配置文件" run_bots "$ENVF" --config "$VD/nope.toml"

cp "$CFG" "$VD/before-f.toml"
printf '[[projects]\nname = "broken"\n' > "$CFG"
OUT=$(run_bots "$ENVF" --config "$CFG")
chk "F 坏配置报错" "不是合法 TOML" "$OUT"
printf '[[projects]\nname = "broken"\n' > "$VD/broken.toml"
cmp -s "$CFG" "$VD/broken.toml" && pass "F 坏配置原样没动" || fail "F 坏配置被改写了"

# 源 project 不是唯一 feishu 平台时必须停手:整块复制会把别的平台凭证也搬过去
make_fixture
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
t += '''
[[projects]]
name = "twoface"

  [projects.agent]
    type = "codex"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_a"
      app_secret = "s"

  [[projects.platforms]]
    type = "telegram"

    [projects.platforms.options]
      token = "t"
'''
p.write_text(t, encoding="utf-8")
PYEOF
BEFORE_TOWFACE=$(md5sum < "$CFG")
check_reject "F 源有两个平台时停手" "不是唯一一个 feishu" run_bots "$ENVF" --config "$CFG" --from twoface
if [ "$(md5sum < "$CFG")" = "$BEFORE_TOWFACE" ]; then
    pass "F 停手时配置一字未动"
else
    fail "F 停手时却写了盘"
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 G:set-allow-from.py 从会话快照发现 open_id"
echo "═══════════════════════════════════════════════════════════"
make_fixture
run_bots "$ENVF" --config "$CFG" >/dev/null 2>&1
DATA="$VD/data"
mkdir -p "$DATA/sessions"
# data_dir 必须指到沙盒里 —— 夹具照抄的是容器路径 /workspace/cc-connect/data,
# 照它去找会话就会在容器路径下找不到(而这里绝不能往容器路径写任何东西)。
# 用 cygpath -m 转成 D:/… 形式:TOML 基本字符串里反斜杠是转义符,不能直接塞 Windows 路径。
DATA_TOML="$(cygpath -m "$DATA" 2>/dev/null || printf '%s' "$DATA" | tr '\\' '/')"
sed -i "s|^data_dir = .*|data_dir = \"$DATA_TOML\"|" "$CFG"
chk "G 夹具的 data_dir 已指到沙盒" "$DATA_TOML" "$(grep '^data_dir' "$CFG")"
# 会话快照形状照抄 cc-connect 的落盘:里面只有会话键字符串是可用的线索,
# 其余字段位置跨版本挪动过(见 set-heartbeat.py 的说明),所以夹具故意把它们放得散乱。
cat > "$DATA/sessions/codex1_1a2b3c4d.json" <<'EOF'
{"sessions": {"s1": {"id": "s1"}},
 "user_meta": {"feishu:oc_new_chat_1:ou_new_owner_1": {"user_name": "me"}},
 "active_session": "feishu:oc_new_chat_1:ou_new_owner_1",
 "updated_at": "2026-09-23T18:46:00Z"}
EOF
cat > "$DATA/sessions/codex2_1a2b3c4d.json" <<'EOF'
{"user_meta": {"feishu:oc_new_chat_2:ou_new_owner_2": {"user_name": "me"}}}
EOF

# 夹具里的两个老 project 都有 allow_from,默认不该被当成目标
OUT=$(run_allow --config "$CFG")
chk "G 巡检模式明说没写盘" "巡检模式:未写盘" "$OUT"
chk "G 发现 codex1 的 ID" "ou_new_owner_1" "$OUT"
chk "G 发现 codex2 的 ID" "ou_new_owner_2" "$OUT"
chk "G 没会话的 codex3 被明说" "没发现会话" "$OUT"
nchk "G 老 codex project 不在目标里" "▸ codex " "$OUT"

cp "$CFG" "$VD/before-g.toml"
OUT=$(run_allow --config "$CFG" --apply)
chk "G 落盘后回验通过" "TOML 回验通过" "$OUT"
got=$(pyget "$CFG" "projects['codex1']['platforms'][0]['options']['allow_from']")
[ "$got" = "ou_new_owner_1" ] && pass "G codex1 的 allow_from 在平台 options 里" || fail "G codex1 allow_from = $got"
got=$(pyget "$CFG" "projects['codex1']['admin_from']")
[ "$got" = "ou_new_owner_1" ] && pass "G codex1 的 admin_from 在 project 顶层" || fail "G codex1 admin_from = $got"
got=$(pyget "$CFG" "projects['codex2']['platforms'][0]['options']['allow_from']")
[ "$got" = "ou_new_owner_2" ] && pass "G 每台机器人写的是自己会话里的 ID" || fail "G codex2 allow_from = $got"
got=$(pyget "$CFG" "projects['codex3']['platforms'][0]['options'].get('allow_from','(none)')")
[ "$got" = "(none)" ] && pass "G 没会话的 codex3 没被写入" || fail "G codex3 被写了 $got"
got=$(pyget "$CFG" "projects['codex']['platforms'][0]['options']['allow_from']")
[ "$got" = "ou_owner_in_old_app" ] && pass "G 老 codex project 的白名单没被动" || fail "G 老 codex 白名单变成了 $got"
got=$(pyget "$CFG" "projects['codex1']['agent']['options']['codex_home']")
[ "$got" = "/workspace/codex-home1" ] && pass "G 写白名单没伤到别的键" || fail "G codex_home 变成了 $got"
[ -f "$CFG.pre-allow" ] && pass "G 留了备份 $CFG.pre-allow" || fail "G 没有备份"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 H:显式 ID / --force / 已有白名单的跳过"
echo "═══════════════════════════════════════════════════════════"
OUT=$(run_allow --config "$CFG")
nchk "H 已回填过的 codex1 不再是目标" "▸ codex1 " "$OUT"
OUT=$(run_allow --config "$CFG" codex1 --force --apply --id ou_forced_me)
chk "H --force 覆盖" "TOML 回验通过" "$OUT"
got=$(pyget "$CFG" "projects['codex1']['platforms'][0]['options']['allow_from']")
[ "$got" = "ou_forced_me" ] && pass "H 显式 ID 写进去了" || fail "H 显式 ID 没生效:$got"
got=$(pyget "$CFG" "projects['codex1']['admin_from']")
[ "$got" = "ou_forced_me" ] && pass "H admin_from 一起更新" || fail "H admin_from = $got"
OUT=$(run_allow --config "$CFG" codex1 --force --apply --id not_an_id)
chk "H 非法 ID 被拒" "不像飞书用户 ID" "$OUT"
OUT=$(run_allow --config "$CFG" nosuchproject --apply)
chk "H 不存在的 project 被拒" "配置里没有 project" "$OUT"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 I:make-bots9-env.py 解析 secret.txt"
echo "═══════════════════════════════════════════════════════════"
SEC="$VD/secret.txt"
{
    for i in 1 2 3 4 5 6 7 8 9; do
        echo "monkey-codex${i}"
        if [ "$i" = 3 ]; then echo "App ID：cli_fullwidth_${i}"; else echo "App ID：cli_fixture_${i}"; fi
        echo "App Secret：sec_fixture_${i}"
        echo
    done
} > "$SEC"
OUT=$("$PY" "$HERE/make-bots9-env.py" --secret "$SEC" --out "$VD/bots9-from-secret.env")
chk "I 解析出 9 个 App" "解析出 9 个 App" "$OUT"
chk "I 段名映射到 project 名" "→ project codex1 " "$OUT"
nchk "I 不打印 App Secret" "sec_fixture_1" "$OUT"
GEN="$VD/bots9-from-secret.env"
[ "$(grep -c '^CODEX[0-9]*_APP_ID=' "$GEN")" = 9 ] && pass "I 生成 9 个 APP_ID 行" || fail "I APP_ID 行数不对"
[ "$(grep -c '^CODEX[0-9]*_APP_SECRET=' "$GEN")" = 9 ] && pass "I 生成 9 个 APP_SECRET 行" || fail "I APP_SECRET 行数不对"
chk "I 全角冒号也能解析" "CODEX3_APP_ID=cli_fullwidth_3" "$(cat "$GEN")"
# 生成物必须能被 add-codex-bots.py 直接吃下去
OUT=$(run_bots "$GEN" --config "$VD/config.toml" --dry-run)
chk "I 生成物能被 add-codex-bots.py 解析" "目标 project: codex1, codex2" "$OUT"
nchk "I 生成物没有解析报错" "键名不认识" "$OUT"

# 混进别的东西必须报错,不能静默少部署
{ echo "bot"; echo "App ID：cli_cmd_bot"; echo "App Secret：s"; } > "$VD/secret-mixed.txt"
cat "$SEC" >> "$VD/secret-mixed.txt"
OUT=$("$PY" "$HERE/make-bots9-env.py" --secret "$VD/secret-mixed.txt" --out "$VD/x.env" 2>&1)
chk "I 段名不是 monkey-codex<N> 时报错" "不是 monkey-codex<序号> 的形状" "$OUT"
{ echo "monkey-codex1"; echo "App ID：cli_a"; echo "App Secret：s"; echo; echo "monkey-codex1"; echo "App ID：cli_b"; echo "App Secret：s"; } > "$VD/secret-dup.txt"
OUT=$("$PY" "$HERE/make-bots9-env.py" --secret "$VD/secret-dup.txt" --out "$VD/x.env" 2>&1)
chk "I 段名重复时报错" "出现了两次" "$OUT"
OUT=$("$PY" "$HERE/make-bots9-env.py" --secret "$VD/nope.txt" --out "$VD/x.env" 2>&1)
chk "I 来源不存在时报错" "找不到凭证来源" "$OUT"

echo
echo "═══════════════════════════════════════════════════════════"
echo " 场景 J:语法自检(三个脚本都要能编译)"
echo "═══════════════════════════════════════════════════════════"
if "$PY" -m py_compile "$HERE/add-codex-bots.py" "$HERE/set-allow-from.py" "$HERE/make-bots9-env.py"; then
    pass "J py_compile 通过"
else
    fail "J py_compile 失败"
fi
rm -rf "$HERE/__pycache__"

echo
echo "═══════════════════════════════════════════"
echo "  通过 $PASS 项，失败 $FAILED 项"
echo "═══════════════════════════════════════════"
[ "$FAILED" = 0 ] || exit 1
