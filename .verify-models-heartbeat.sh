#!/bin/bash
# 本地验证 deploy-codex.sh 的模型别名/心跳生成 + set-heartbeat.py 的会话键发现与改写
#
# 做法:不连容器。把 deploy-codex.sh 里那段生成配置的 Python 原样抽出来跑,
# 再用标准库 tomllib 解析生成物 —— 配置错一处 cc-connect 就起不来,
# 这种错必须在本地拦住,不能等到容器里以"机器人没反应"的形式暴露。
#
# 只用项目内沙盒目录,不碰任何外部路径。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VD="$HERE/.verify-mh"
SB="$VD/sb"
PY="${PY:-python}"

# Windows 上 python 默认按 GBK 编码 stdout,打印 ✅ 会抛 UnicodeEncodeError。
# 容器是 UTF-8,所以这只是本地测试环境的差异 —— 但被测脚本自己也得扛住,
# 见第 13 步(那里刻意不设这个变量)。
export PYTHONUTF8=1

rm -rf "$VD"
mkdir -p "$SB/cc-connect/data/sessions"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

CFG="$SB/cc-connect/config.toml"

# ---------- 1. 语法检查 ----------
echo "══ 1. deploy-codex.sh / set-heartbeat.py 静态检查 ══"
bash -n "$HERE/deploy-codex.sh" && ok "deploy-codex.sh 语法通过" || fail "deploy-codex.sh 语法错误"
"$PY" -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" \
    "$HERE/set-heartbeat.py" && ok "set-heartbeat.py 语法通过" || fail "set-heartbeat.py 语法错误"
echo

# ---------- 2. 抽出生成配置的那段 Python 并跑起来 ----------
echo "══ 2. 生成配置(模型别名 + 心跳) ══"
GEN="$VD/gen.py"
awk '/python3 - <<.PYEOF./{f=1;next} /^PYEOF[[:space:]]*$/{f=0} f' "$HERE/deploy-codex.sh" > "$GEN"
[ -s "$GEN" ] || { echo "❌ 没能从 deploy-codex.sh 抽出生成器"; exit 1; }

# 把两个写死路径改到沙盒;真实脚本里它们是容器路径,这里只换目标不改逻辑
"$PY" - "$GEN" "$CFG" "$SB/feishu-bot/feishu-bot-config.json" <<'PATCH'
import pathlib, sys
gen, cfg, bot = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(gen).read_text(encoding="utf-8")
before = text
text = text.replace('pathlib.Path("/workspace/cc-connect/config.toml")',
                    f'pathlib.Path({cfg!r})')
text = text.replace('pathlib.Path("/workspace/feishu-bot/feishu-bot-config.json")',
                    f'pathlib.Path({bot!r})')
assert text != before, "路径替换没生效 —— deploy-codex.sh 里的路径写法变了"
pathlib.Path(gen).write_text(text, encoding="utf-8")
PATCH

MODE=new \
CODEX_KEY=sk-fake-codex CODEX_MODEL=gpt-5.3-codex CODEX_BASE=https://relay.example/v1 \
CODEX_PROVIDER_NAME=main CODEX_MODELS='gpt-5.3-codex:codex,gpt-5.4:gpt,gpt-5.3-codex-spark' \
CLAUDE_FEISHU_APP_ID=cli_fakeclaude001 CLAUDE_FEISHU_APP_SECRET=fakesecret \
CLAUDE_KEY=sk-fake-claude CLAUDE_MODEL=claude-opus-4-5 CLAUDE_BASE=https://relay.example/anthropic \
CLAUDE_PROVIDER_NAME=main CLAUDE_MODELS='claude-opus-4-5:opus,claude-sonnet-4-5:sonnet' \
WANT_CLAUDE=1 \
HEARTBEAT_SESSION_KEY='feishu:oc_deadbeef:ou_cafebabe' HEARTBEAT_INTERVAL_MINS=45 \
HEARTBEAT_PROMPT='检查未完成的任务并继续' \
CODEX_FEISHU_APP_ID=cli_fakecodex001 CODEX_FEISHU_APP_SECRET=fakesecret \
"$PY" "$GEN" > "$VD/gen.out" 2>&1
GEN_RC=$?
sed 's/^/  /' "$VD/gen.out"
[ "$GEN_RC" = "0" ] || fail "生成器退出码 $GEN_RC"
echo

# ---------- 3. 用真实 TOML 解析器回验生成物 ----------
echo "══ 3. 回验生成的 config.toml ══"
"$PY" - "$CFG" <<'PYEOF'
import os, pathlib, sys, tomllib

cfg = pathlib.Path(sys.argv[1])
doc = tomllib.loads(cfg.read_text(encoding="utf-8"))
projs = {p["name"]: p for p in doc["projects"]}
bad = []
def want(cond, msg):
    if not cond:
        bad.append(msg)

want(set(projs) == {"codex", "claude"}, f"project 集合不对: {set(projs)}")

cx = projs["codex"]["agent"]["providers"][0]
want(cx["model"] == "gpt-5.3-codex", "codex 主模型不对")
want([m["model"] for m in cx["models"]] ==
     ["gpt-5.3-codex", "gpt-5.4", "gpt-5.3-codex-spark"], "codex 模型列表不对")
want([m.get("alias") for m in cx["models"]] == ["codex", "gpt", None],
     "codex 别名不对(第三条应省略 alias)")

cl = projs["claude"]["agent"]["providers"][0]
want([m.get("alias") for m in cl["models"]] == ["opus", "sonnet"], "claude 别名不对")
# 别名子表不能把 providers.env 挤掉:两个都是 provider 的子表,必须同时存在
want("env" in cl, "claude 的 providers.env 被模型别名挤掉了")
want(cl["env"]["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "claude-opus-4-5", "providers.env 值不对")

hb = projs["codex"].get("heartbeat")
want(hb is not None, "codex 缺少 heartbeat 段")
if hb:
    want(hb["enabled"] is True, "heartbeat.enabled 不为 true")
    want(hb["session_key"] == "feishu:oc_deadbeef:ou_cafebabe", "heartbeat.session_key 不对")
    want(hb["interval_mins"] == 45, "heartbeat.interval_mins 不对")
    want(hb["prompt"] == "检查未完成的任务并继续", "heartbeat.prompt 不对(中文或转义有问题)")
# 心跳只能挂在 codex 上,不能串到 claude
want("heartbeat" not in projs["claude"], "心跳串到了 claude")

# 权限位只在 POSIX 文件系统上有意义:Windows 的 chmod 只映射只读标志,
# 拿它断言会永远失败。容器是 Linux,那里这条才真正生效。
if os.name == "posix":
    want(cfg.stat().st_mode & 0o777 == 0o600, "配置权限不是 600(含密钥,必须收紧)")


if bad:
    print("  ❌ 回验失败:")
    for b in bad:
        print(f"     - {b}")
    sys.exit(1)
print("  ✅ TOML 解析通过,字段逐个核对无误")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 4. 复用模式(有 owner)时心跳段的落点 ----------
# 新建模式下 owner 通常为空,allow_from 整行省略;复用模式下 owner 一定有,
# 心跳段会紧跟在一堆 platforms.options 键之后 —— 落点不同,得单独验一次,
# 否则可能把 allow_from 抢进 heartbeat 子表里。
echo "══ 4. 复用模式(有 owner)下心跳段的落点 ══"
CFG2="$SB/cc-connect/config-reuse.toml"
mkdir -p "$SB/feishu-bot"
cat > "$SB/feishu-bot/feishu-bot-config.json" <<'EOF'
{"app_id": "cli_reuse001", "app_secret": "reuse-secret", "owner_open_id": "ou_reuseowner"}
EOF
cp "$GEN" "$VD/gen-reuse.py"
"$PY" - "$VD/gen-reuse.py" "$CFG2" <<'PATCH'
import pathlib, re, sys
p, cfg2 = pathlib.Path(sys.argv[1]), sys.argv[2]
text = p.read_text(encoding="utf-8")
new, n = re.subn(r"pathlib\.Path\('[^']*config\.toml'\)",
                 f"pathlib.Path({cfg2!r})", text)
assert n == 1, f"输出路径替换命中 {n} 次(期望 1 次)—— 生成器的写法变了"
p.write_text(new, encoding="utf-8")
PATCH
MODE=reuse CODEX_KEY=k CODEX_MODEL=m CODEX_BASE=https://x/v1 CODEX_MODELS='m:main' \
WANT_CLAUDE=0 HEARTBEAT_SESSION_KEY='feishu:oc_reuse:ou_reuseowner' \
HEARTBEAT_INTERVAL_MINS=30 \
"$PY" "$VD/gen-reuse.py" > "$VD/reuse.out" 2>&1
sed 's/^/  /' "$VD/reuse.out"
"$PY" - "$CFG2" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cx = {p["name"]: p for p in doc["projects"]}["codex"]
bad = []
if cx.get("admin_from") != "ou_reuseowner":
    bad.append(f"admin_from 丢了: {cx.get('admin_from')!r}")
plat = cx["platforms"][0]["options"]
if plat.get("allow_from") != "ou_reuseowner":
    bad.append(f"allow_from 没落到 platforms.options: {plat}")
if plat.get("app_id") != "cli_reuse001":
    bad.append(f"platforms.options 内容不对: {plat}")
hb = cx.get("heartbeat") or {}
if hb.get("session_key") != "feishu:oc_reuse:ou_reuseowner":
    bad.append(f"心跳没落到 codex 上: {hb}")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ allow_from 留在 platforms.options,心跳独立成段,两者互不侵占")
PYEOF
[ $? = 0 ] || FAIL=1
rm -f "$SB/feishu-bot/feishu-bot-config.json"
echo

# ---------- 5. 别名重复必须被拦下 ----------
echo "══ 5. 别名重复要报错(不能静默丢弃) ══"
MODE=new CODEX_KEY=k CODEX_MODEL=m CODEX_BASE=https://x/v1 CODEX_MODELS='a:dup,b:dup' \
CODEX_FEISHU_APP_ID=cli_x CODEX_FEISHU_APP_SECRET=y WANT_CLAUDE=0 \
HEARTBEAT_SESSION_KEY= HEARTBEAT_INTERVAL_MINS= HEARTBEAT_PROMPT= \
"$PY" "$GEN" > "$VD/dup.out" 2>&1
if grep -q "别名重复" "$VD/dup.out"; then
    ok "重复别名被拒绝: $(grep '别名重复' "$VD/dup.out" | head -1)"
else
    fail "重复别名没有被拦下"; sed 's/^/     /' "$VD/dup.out" | head -5
fi
echo

# ---------- 6. set-heartbeat.py:会话键发现 ----------
echo "══ 6. set-heartbeat.py 会话键发现 ══"
# 把 data_dir 指到沙盒(生成物里是容器路径)
"$PY" - "$CFG" "$SB/cc-connect/data" <<'PATCH'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text(encoding="utf-8").replace(
    'data_dir = "/workspace/cc-connect/data"', f'data_dir = "{sys.argv[2]}"'), encoding="utf-8")
PATCH

SESS="$SB/cc-connect/data/sessions/codex_1a2b3c4d.json"

# 造一份**真实形状**的会话快照。血的教训:这里原先写的是
#   {"sessions": {"feishu:oc_xxx:ou_yyy": {...}}}
# 即把会话键直接当 sessions 表的键 —— 于是自动发现"永远能发现",测试全绿。
# 但真实快照不长这样:core/session.go 里 sessions 是按**内部 ID**(s1/s4,
# nextID 生成,形如 s 加递增数字)索引的,会话键只出现在 active_session /
# user_sessions(userKey)和 user_meta(sessionKey)上。线上跑的是真快照,
# 旧实现按 key.count(":") < 2 过滤内部 ID,一条都留不下,返回空 ——
# 也就是用户看到的"没有会话"。测试替错误假设背了书,这条教训写在这。
# 形状必须照源码来,且由第 6 节的断言钉死。
#
# 用法: write_snapshot <文件> <会话键> [<会话键> ...]
write_snapshot() {
    local out="$1"; shift
    "$PY" - "$out" "$@" <<PYEOF
import json, pathlib, sys
out, keys = sys.argv[1], sys.argv[2:]
# 顺带把真快照的两个诱饵原样带上:内部 ID(s1)与 ISO 时间戳(含两个冒号),
# 两者都**不能**被当成会话键 —— 第 6 节 6b 专门验这个。
snap = {
    "sessions": {f"s{i + 1}": {"id": f"s{i + 1}",
                               "created_at": "2026-09-19T09:00:00Z",
                               "updated_at": "2026-09-19T10:00:00Z"}
                 for i in range(len(keys))},
    "active_session": {k: f"s{i + 1}" for i, k in enumerate(keys)},
    "user_sessions": {k: [f"s{i + 1}"] for i, k in enumerate(keys)},
    "user_meta": {k: {"user_name": "u", "chat_name": "c"} for k in keys},
    "counter": len(keys),
}
pathlib.Path(out).write_text(json.dumps(snap, ensure_ascii=False), encoding="utf-8")
PYEOF
}

write_snapshot "$SESS" feishu:oc_realchat01:ou_realuser01 telegram:123:456

"$PY" "$HERE/set-heartbeat.py" --config "$CFG" > "$VD/list.out" 2>&1
sed 's/^/  /' "$VD/list.out"
grep -q "feishu:oc_realchat01:ou_realuser01" "$VD/list.out" \
    && ok "巡检能列出飞书会话键" || fail "巡检没列出会话键"
grep -q "telegram:123:456" "$VD/list.out" \
    && ok "巡检也列出了其它平台的键(未按平台过滤,交给下一步挑)" || fail "漏了其它平台的键"
echo

# ---------- 6b. 只认会话键(误报 / 鲁棒性 / 负对照) ----------
# 第 6 节只证明"能发现",这一节证明"发现的是对的东西",且不依赖会话键恰好落在哪个字段。
echo "══ 6b. 只认会话键:不误报内部 ID 与时间戳,且不写死字段 ══"

# 从巡检输出里抽会话键。实际排版是两行式:
#     "  codex:"
#     "    feishu:oc_realchat01:ou_realuser01    (最近活动 ...)"
# 键在**缩进 4 空格**的那一行上,project 名单独占一行;没有会话时则并成一行
# "  claude: (没有会话 —— ...)"。所以先按 4 空格缩进取,再用"至少两段冒号"滤一遍 ——
# 两道都不能省:本断言第一版只认 "project: 键",把 "(没有会话" 当成了键(四条用例集体误报)。
keys_of() {
    sed -n 's/^    \([^ ]*\).*/\1/p' "$1" \
        | grep -E '^[A-Za-z][A-Za-z0-9_-]*(:[^ :]+){2,}$' | sort
}

# 形状守卫:假快照若退回"会话键当 sessions 键"的旧形状(就是它让本脚本一直全绿),
# 整个 6~10 节又会变成替错误假设背书 —— 所以这里必须当场炸。
"$PY" - "$SESS" <<'PYEOF'
import json, pathlib, sys
snap = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
bad = [k for k in snap["sessions"] if ":" in k]
print("  ✅ 假快照形状正确:sessions 按内部 ID 索引" if not bad
      else f"  ❌ 假快照退回了旧形状,sessions 的键里出现了会话键: {bad}")
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || FAIL=1

# 误报:输出里的键必须**恰好**是这两个。快照里那两个诱饵 —— 内部 ID(s1/s2)和
# ISO 时间戳(2026-09-19T10:00:00Z,也含两个冒号)—— 一个都不许混进来。
GOT="$(keys_of "$VD/list.out" | tr '\n' ' ')"
[ "$GOT" = "feishu:oc_realchat01:ou_realuser01 telegram:123:456 " ] \
    && ok "巡检只列出这两个会话键(内部 ID 与时间戳都没被误认)" \
    || fail "巡检列出的键不对: [$GOT]"

# 鲁棒性:会话键落在这三个字段中的哪个不可控(跨版本挪过位置,见文件头),
# 逐个字段单独验一遍 —— 旧实现只认 sessions 表,正是一头撞死在这上面。
#
# 每轮必须先 write_snapshot 重建:这个循环是**就地清空**另外两个字段的,
# 不重建的话第 1 轮就把 user_sessions / user_meta 永久清掉了,后面两轮读到的是
# 上一轮的残骸,会集体误报"发现不了"(本用例第一版正是这么错的)。
for field in active_session user_sessions user_meta; do
    write_snapshot "$SESS" feishu:oc_realchat01:ou_realuser01 telegram:123:456
    "$PY" - "$SESS" "$field" <<'PYEOF'
import json, pathlib, sys
p, keep = pathlib.Path(sys.argv[1]), sys.argv[2]
snap = json.loads(p.read_text(encoding="utf-8"))
for f in ("active_session", "user_sessions", "user_meta"):
    if f != keep:
        snap[f] = {}
p.write_text(json.dumps(snap, ensure_ascii=False), encoding="utf-8")
PYEOF
    "$PY" "$HERE/set-heartbeat.py" --config "$CFG" > "$VD/only_$field.out" 2>&1
    [ "$(keys_of "$VD/only_$field.out" | tr '\n' ' ')" = \
      "feishu:oc_realchat01:ou_realuser01 telegram:123:456 " ] \
        && ok "会话键只存在于 $field 时仍能发现" \
        || fail "只保留 $field 就发现不了了 —— 落点又被写死了"
done

# 负对照:三个字段全清空,只留 sessions 表(内部 ID + 时间戳)。必须一个都发现不了,
# 否则说明命中的是快照里别的东西 —— 那第 6 节和上面几条就都不成立。
"$PY" - "$SESS" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
snap = json.loads(p.read_text(encoding="utf-8"))
for f in ("active_session", "user_sessions", "user_meta"):
    snap[f] = {}
p.write_text(json.dumps(snap, ensure_ascii=False), encoding="utf-8")
PYEOF
"$PY" "$HERE/set-heartbeat.py" --config "$CFG" > "$VD/neg.out" 2>&1
NEG="$(keys_of "$VD/neg.out" | tr '\n' ' ')"
[ -z "$NEG" ] && ok "负对照:清空三个字段后一个键都发现不了(命中的确实是会话键)" \
    || fail "负对照失败,清空后仍发现: [$NEG]"
echo

# ---------- 7. 唯一飞书键时自动启用 ----------
echo "══ 7. 唯一候选时自动发现并启用 ══"
write_snapshot "$SESS" feishu:oc_realchat01:ou_realuser01     # 只留一个候选

"$PY" "$HERE/set-heartbeat.py" codex --config "$CFG" --interval 20 > "$VD/auto.out" 2>&1
sed 's/^/  /' "$VD/auto.out"
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
projs = {p["name"]: p for p in doc["projects"]}
hb = projs["codex"].get("heartbeat") or {}
bad = []
if hb.get("session_key") != "feishu:oc_realchat01:ou_realuser01":
    bad.append(f"session_key 不对: {hb.get('session_key')!r}")
if hb.get("enabled") is not True:
    bad.append("enabled 不为 true")
if hb.get("interval_mins") != 20:
    bad.append(f"interval_mins 不对: {hb.get('interval_mins')!r}")
# 改写后必须仍然只有一份心跳段,重复表头会让 TOML 解析直接失败
if pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").count("[projects.heartbeat]") != 1:
    bad.append("心跳段出现了不止一次")
# 原有内容不能被改写弄丢
if set(projs) != {"codex", "claude"}:
    bad.append(f"project 丢了: {set(projs)}")
if [m.get("alias") for m in projs["claude"]["agent"]["providers"][0]["models"]] != ["opus", "sonnet"]:
    bad.append("claude 的模型别名在改写后丢失")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ 会话键自动发现正确,改写后配置仍合法,其它段完好")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 8. 重复改写应原地替换,不能堆叠 ----------
echo "══ 8. 再次改写要原地替换(不堆叠) ══"
"$PY" "$HERE/set-heartbeat.py" codex --config "$CFG" --interval 99 > "$VD/again.out" 2>&1
N=$(grep -c '^\[projects.heartbeat\]\|^  \[projects\.heartbeat\]' "$CFG")
[ "$N" = "1" ] && ok "仍只有一份心跳段" || fail "心跳段堆叠成了 $N 份"
grep -q 'interval_mins = 99' "$CFG" && ok "间隔已更新为 99" || fail "间隔没更新"
echo

# ---------- 9. 多候选时必须拒绝猜 ----------
echo "══ 9. 多个候选会话键时应拒绝自动选择 ══"
write_snapshot "$SESS" feishu:oc_chatA:ou_user feishu:oc_chatB:ou_user
"$PY" "$HERE/set-heartbeat.py" codex --config "$CFG" > "$VD/multi.out" 2>&1
RC=$?
sed 's/^/  /' "$VD/multi.out"
[ "$RC" != "0" ] && ok "多候选时按预期退出(不猜)" || fail "多候选时竟然自动选了一个"
grep -q 'oc_chatB' "$VD/multi.out" && ok "候选都列了出来供人工指定" || fail "没列出候选"
echo

# ---------- 10. 没有任何会话时要给出可操作的提示 ----------
echo "══ 10. 无会话时应提示先发消息 ══"
rm -f "$SESS"
"$PY" "$HERE/set-heartbeat.py" codex --config "$CFG" > "$VD/none.out" 2>&1
RC=$?
[ "$RC" != "0" ] && ok "无会话时按预期退出" || fail "无会话时竟然成功了"
grep -q '先.*发一条消息' "$VD/none.out" && ok "提示了要先给机器人发消息" || fail "缺少可操作提示"
echo

# ---------- 11. --off 关闭并保留键 ----------
echo "══ 11. --off 关闭心跳 ══"
"$PY" "$HERE/set-heartbeat.py" codex --config "$CFG" --off > "$VD/off.out" 2>&1
sed 's/^/  /' "$VD/off.out"
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
hb = {p["name"]: p for p in doc["projects"]}["codex"].get("heartbeat") or {}
if hb.get("enabled") is not False:
    print(f"  ❌ enabled 应为 false,实得 {hb.get('enabled')!r}"); sys.exit(1)
if not hb.get("session_key"):
    print("  ❌ 关闭时应保留 session_key 以便再开"); sys.exit(1)
print(f"  ✅ 已关闭且保留了会话键 {hb['session_key']}")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 12. 显式 --key 时跳过发现 ----------
echo "══ 12. --key 显式指定 ══"
"$PY" "$HERE/set-heartbeat.py" claude --config "$CFG" --key feishu:oc_manual:ou_manual > "$VD/key.out" 2>&1
sed 's/^/  /' "$VD/key.out"
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
p = {x["name"]: x for x in doc["projects"]}
hb = p["claude"].get("heartbeat") or {}
bad = []
if hb.get("session_key") != "feishu:oc_manual:ou_manual":
    bad.append("显式 key 没写进去")
if "heartbeat" in p["codex"] and p["codex"]["heartbeat"].get("enabled") is not False:
    bad.append("改 claude 时把 codex 的心跳弄坏了")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ 显式键写入正确,且没有影响另一个 project")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 13. 两个开关：给值才写，不给就不写 ----------
# 本机心跳是 only_when_idle=true / silent=false。要把它搬到容器,就必须能表达
# false 这一侧 —— 若实现里用 `if silent` 判,False 会被当成"没给"而丢弃,
# 结果是想关的没关掉,且不报任何错。
echo "══ 13. silent / only_when_idle 开关 ══"
"$PY" "$HERE/set-heartbeat.py" claude --config "$CFG" --key feishu:oc_manual:ou_manual \
    --interval 1 --timeout 1 --only-when-idle --no-silent --prompt "请继续之前的工作" \
    > "$VD/sw.out" 2>&1
[ $? = 0 ] || { fail "带开关运行失败"; tail -5 "$VD/sw.out"; }
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
hb = {x["name"]: x for x in doc["projects"]}["claude"]["heartbeat"]
bad = []
# 这六个正是本机 codex-test2 / claude-test2 heartbeat 段的实际取值
for k, want in (("enabled", True), ("interval_mins", 1), ("timeout_mins", 1),
                ("only_when_idle", True), ("silent", False), ("prompt", "请继续之前的工作")):
    if hb.get(k) != want:
        bad.append(f"{k} 期望 {want!r},实得 {hb.get(k)!r}")
if bad:
    print("  ❌ " + "; ".join(bad)); sys.exit(1)
print("  ✅ 六个字段与本机一致(silent=false 没被当成“没给”丢掉)")
PYEOF
[ $? = 0 ] || FAIL=1

"$PY" "$HERE/set-heartbeat.py" claude --config "$CFG" --key feishu:oc_manual:ou_manual \
    > "$VD/sw2.out" 2>&1
[ $? = 0 ] || { fail "不带开关运行失败"; tail -5 "$VD/sw2.out"; }
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
doc = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
hb = {x["name"]: x for x in doc["projects"]}["claude"]["heartbeat"]
leaked = [k for k in ("silent", "only_when_idle") if k in hb]
if leaked:
    print(f"  ❌ 没给开关却写进了配置: {leaked}"); sys.exit(1)
print("  ✅ 没给开关时不写该项,沿用 cc-connect 默认值")
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 14. 非 UTF-8 环境下也不能崩 ----------
# 回归防线:脚本要在"配置已写好之后"打印 ✅,若这行因编码抛异常,
# 退出码会变成非零 —— 用户以为部署失败,实际配置是好的,极难排查。
echo "══ 14. 非 UTF-8 输出环境下仍要正常收尾 ══"
write_snapshot "$SESS" feishu:oc_enc:ou_enc
env -u PYTHONUTF8 -u PYTHONIOENCODING "$PY" "$HERE/set-heartbeat.py" codex \
    --config "$CFG" --interval 15 > "$VD/enc.out" 2>&1
RC=$?
if [ "$RC" = "0" ]; then
    ok "无 PYTHONUTF8 时仍以 0 退出"
else
    fail "无 PYTHONUTF8 时退出码 $RC(编码问题会让部署被误判为失败)"
    sed 's/^/     /' "$VD/enc.out" | tail -5
fi
"$PY" - "$CFG" <<'PYEOF'
import pathlib, sys, tomllib
hb = {p["name"]: p for p in tomllib.loads(
    pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["projects"]}["codex"]["heartbeat"]
sys.exit(0 if hb.get("interval_mins") == 15 else 1)
PYEOF
[ $? = 0 ] || fail "非 UTF-8 环境那次改写没落盘"
echo

# ---------- 14. 字段名必须在 v1.5.0 里真实存在 ----------
# 心跳/models 都是强类型字段(config.go 的 ProjectConfig.Heartbeat、ProviderModelConfig),
# 名字写错不会报错,只会被 TOML 解码器静默忽略 —— 也就是"配了但不生效"。
# 拿真实源码的 toml 标签核对,才能挡住这类错。
# 源码目录不存在就跳过(它不是本仓库的一部分;获取方式见下方提示)。
SRC="$HERE/.cache/cc-connect-src"
echo "══ 15. 字段名与 v1.5.0 源码双向核对 ══"
if [ -d "$SRC" ]; then
"$PY" - "$SRC" "$CFG" <<'PYEOF'
import pathlib, re, sys, tomllib

src, cfg = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
known = set()
for p in src.rglob("*.go"):
    if p.name.endswith("_test.go"):
        continue
    known |= set(re.findall(r'toml:"([A-Za-z0-9_]+)', p.read_text(encoding="utf-8", errors="ignore")))

# 自由键容器:内容由 agent / 平台各自定义,源码里查不到标签是正常的
FREE = {"ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "app_id", "app_secret",
        "approval_policy", "codex_home", "sandbox_mode"}

used = set()
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            used.add(k); walk(v)
    elif isinstance(node, list):
        for v in node: walk(v)
walk(tomllib.loads(cfg.read_text(encoding="utf-8")))

unknown = sorted(used - known - FREE)
if unknown:
    print("  ❌ 下列键在 v1.5.0 源码里没有对应标签(会被静默忽略):")
    for k in unknown:
        print(f"     - {k}")
    sys.exit(1)
# 强类型字段要逐个点名确认,不能只靠"没出现在 unknown 里"
for must in ("heartbeat", "session_key", "interval_mins", "models", "alias", "data_dir"):
    if must not in known:
        print(f"  ❌ 关键字段 {must!r} 在 v1.5.0 源码里不存在")
        sys.exit(1)
print(f"  ✅ 配置用到的 {len(used)} 个键全部有据可查"
      f"(源码 {len(known)} 个标签;{len(used & FREE)} 个自由键已豁免)")
print(f"     强类型字段已点名确认: heartbeat / session_key / interval_mins / models / alias / data_dir")
PYEOF
[ $? = 0 ] || FAIL=1
else
    echo "  ➖ 跳过(未找到 $SRC)"
    echo "     获取: gh api repos/chenhg5/cc-connect/tarball/17c61062 | tar xz -C <目录> --strip-components=1"
fi
echo

# ---------- 16. 产物不外泄 ----------
echo "══ 16. 沙盒之外没有写入 ══"
[ -d "$HERE/.verify-mh" ] && ok "所有产物都在 $VD 内" || fail "沙盒目录异常"
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
