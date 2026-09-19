#!/bin/bash
# 本地验证 make-whitelist-cmd.sh 生成的白名单补丁
#
# 关键点与上传脚本同理:不能只看它"打印了什么",要把生成的命令**真的跑一遍**,
# 再检查目标文件改成了什么样。白名单写坏 = 机器人整体失联,且现场在容器里、
# 排查要绕一圈飞书。所以这里把补丁的落点、幂等性、拒绝非法输入都钉死。
#
# 最要紧的一条:**两个 project 必须各写各的 open_id**。飞书 open_id 按应用隔离,
# 同一个人在新机器人和 claude 机器人眼里是两串不同的值;把 codex 那串填进
# claude 的 allow_from,表现就是"claude 机器人对你不理不睬",而且完全静默。

set -uo pipefail

# 不给真剪贴板塞东西:这个脚本要连着跑好几次补丁
export WL_NO_CLIP=1
# Windows 上的 python.exe 不认 /d/... 这种 MSYS 路径(会被当成 \d\...),
# 凡是要交给 python 的路径都得先转成 D:/... 混写形式。
export PYTHONIOENCODING=utf-8
w() { cygpath -m "$1"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
VD="$HERE/.verify-whitelist"
SB="$VD/sb"
PY="${PY:-python}"

rm -rf "$VD"
mkdir -p "$SB"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

ID_C="ou_495e828fbe7b2d150cfd156ddd464bb1"
ID_L="ou_8ca9a25d07e0e9f646a2c2d3670deb94"

# 容器的 config.toml 是 deploy-codex.sh 生成的:白名单没配过,那两行压根不存在。
mk_config() {
    cat > "$SB/config.toml" <<'EOF'
data_dir = "/workspace/cc-connect/data"

[[projects]]
name = "codex"
  [projects.agent]
    type = "codex"

    [projects.agent.options]
      work_dir = "/workspace"
      provider = "main"

    [[projects.agent.providers]]
      name = "main"
      api_key = "sk-x"
      base_url = "https://relay.example/v22/v1"
      model = "deepseek-v4-flash"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_aaa"
      app_secret = "secret-aaa"

[[projects]]
name = "claude"
  [projects.agent]
    type = "claudecode"

    [projects.agent.options]
      work_dir = "/workspace"
      provider = "main"

    [[projects.agent.providers]]
      name = "main"
      api_key = "sk-y"
      base_url = "https://relay.example/v3"
      model = "deepseek-v4-flash"

  [[projects.platforms]]
    type = "feishu"

    [projects.platforms.options]
      app_id = "cli_bbb"
      app_secret = "secret-bbb"
EOF
}

# 把生成的命令抠出来,改写路径到沙盒后再执行 —— 改写处数必须对得上,
# 少改一处就会写到 /workspace(本项目之外),所以先断言再替换。
run_patch() {
    local out="$VD/gen.out"
    bash "$HERE/make-whitelist-cmd.sh" "$@" > "$out" 2>&1
    [ $? = 0 ] || { fail "生成失败"; tail -3 "$out"; return 1; }

    local line; line="$(sed -n '/=== 下面这一整行就是命令/,+2p' "$out" | sed -n '2p')"
    [ -n "$line" ] || { fail "没抠出命令体"; return 1; }

    local b64; b64="$(printf '%s' "$line" | awk '{print $2}')"
    [ -n "$b64" ] || { fail "命令体里没有 base64 段"; return 1; }
    printf '%s' "$b64" | base64 -d | gunzip > "$VD/patch.py" || { fail "解不出补丁脚本"; return 1; }

    local n; n="$(grep -c '/workspace/cc-connect/config.toml' "$VD/patch.py")"
    [ "$n" = "1" ] || { fail "补丁里的目标路径命中 $n 次(应为 1),不敢改写"; return 1; }
    sed "s#/workspace/cc-connect/config.toml#$(w "$SB")/config.toml#" "$VD/patch.py" > "$VD/patch-sb.py"

    "$PY" "$(w "$VD")/patch-sb.py"
}

# ---------- 1. 语法与参数校验 ----------
echo "══ 1. 参数校验 ══"
bash -n "$HERE/make-whitelist-cmd.sh" && ok "语法通过" || fail "语法错误"

bash "$HERE/make-whitelist-cmd.sh" >/dev/null 2>&1 && fail "一个参数都不给竟然被接受" || true
ok "不给任何 --codex/--claude 一律拒绝"

for bad in "cli_abc" "ou_" "ou_1a2b 3c" "ou_1a2b'3c"; do
    # 必须带引号:不带的话 "ou_1a2b 3c" 会被拆成两个参数,测的就成了另一个 id
    bash "$HERE/make-whitelist-cmd.sh" --codex "$bad" >/dev/null 2>&1 \
        && fail "非法 open_id $(printf '[%s]' "$bad") 竟然被接受" \
        || true
done
ok "非 ou_ 前缀 / 含空格 / 含引号 一律拒绝"

bash "$HERE/make-whitelist-cmd.sh" --codex "$ID_C" --whoops >/dev/null 2>&1 \
    && fail "未知参数竟然被接受" || ok "未知参数被拒"
bash "$HERE/make-whitelist-cmd.sh" --codex >/dev/null 2>&1 \
    && fail "--codex 后面不跟值时竟然被接受" || ok "--codex 缺值被拒"
echo

# ---------- 2. 两个 project 各写各的 id ----------
echo "══ 2. codex 与 claude 写不同的 open_id ══"
mk_config
run_patch --codex "$ID_C" --claude "$ID_L" > "$VD/r2.log" 2>&1 || fail "补丁执行失败"
grep -q '白名单已写入' "$VD/r2.log" && ok "报了大功告成" || { fail "没报成功"; sed 's/^/     /' "$VD/r2.log"; }

"$PY" - "$(w "$SB")/config.toml" "$ID_C" "$ID_L" <<'PYEOF'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
ic, il = sys.argv[2], sys.argv[3]
blocks = {}
starts = [i for i, l in enumerate(text.splitlines()) if l.strip() == "[[projects]]"]
lines = text.splitlines()
for n, s in enumerate(starts):
    e = starts[n + 1] if n + 1 < len(starts) else len(lines)
    seg = "\n".join(lines[s:e])
    nm = re.search(r'^name = "([^"]*)"', seg, re.M).group(1)
    blocks[nm] = seg
bad = []
for name, uid, other in (("codex", ic, il), ("claude", il, ic)):
    seg = blocks.get(name, "")
    if f'admin_from = "{uid}"' not in seg:
        bad.append(f"{name} 缺少 admin_from = {uid}")
    if f'allow_from = "{uid}"' not in seg:
        bad.append(f"{name} 缺少 allow_from = {uid}")
    if other in seg:
        bad.append(f"{name} 区块里混进了另一个 App 的 id {other}")
print("  ✅ 两个 project 各拿到自己的 id,且没有串台" if not bad
      else "  ❌ " + "; ".join(bad))
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || FAIL=1

# admin_from 必须落在 [[projects]] 顶层:紧跟在 name 行之后
grep -A1 '^name = "codex"$' "$SB/config.toml" | grep -q "^admin_from = \"$ID_C\"$" \
    && ok "admin_from 位置正确(紧跟 name 行)" || fail "admin_from 插错位置"
# allow_from 必须在 platforms.options 里:紧跟在 app_secret 之后
grep -A1 '^      app_secret = ' "$SB/config.toml" | grep -q 'allow_from' \
    && ok "allow_from 位置正确(紧跟 app_secret)" || fail "allow_from 插错位置"
"$PY" -c "import tomllib,pathlib;d=tomllib.loads(pathlib.Path(r'$(w "$SB")/config.toml').read_text(encoding='utf-8'));print('  OK 改完仍是合法 TOML,project 数',len(d['projects']))" \
    || fail "改完解析不了"
if [ -s "$SB/config.toml.pre-whitelist" ] && [ "$(grep -c 'admin_from' "$SB/config.toml.pre-whitelist")" = "0" ]; then
    ok "留了改前备份 pre-whitelist(里面还没有 admin_from)"
else
    fail "备份缺失或存的是改后内容,等于没备份"
fi
[ -f "$SB/config.toml.new" ] && fail "留下半截 .new" || ok "没留下半截 .new"
echo

# ---------- 3. 幂等:再跑一次必须只改值、不重复插入 ----------
echo "══ 3. 重复执行幂等(不许越插越多) ══"
run_patch --codex "$ID_C" --claude "$ID_L" > "$VD/r3.log" 2>&1
[ "$(grep -c '^admin_from' "$SB/config.toml")" = "2" ] && ok "admin_from 仍是 2 处" || fail "admin_from 被插重了"
[ "$(grep -c 'allow_from' "$SB/config.toml")" = "2" ] && ok "allow_from 仍是 2 处" || fail "allow_from 被插重了"
grep -q 'admin_from = 改值' "$VD/r3.log" && ok "第二次走的是改值分支" || fail "第二次没走改值分支"
echo

# ---------- 4. 只点名一个 project:另一个必须一个字都不动 ----------
echo "══ 4. 只给 --codex 时 claude 不动 ══"
mk_config
run_patch --codex "$ID_C" > "$VD/r4.log" 2>&1
[ "$(grep -c "$ID_C" "$SB/config.toml")" = "2" ] && ok "codex 写入了 2 处(admin + allow)" || fail "codex 写入处数不对"
"$PY" - "$(w "$SB")/config.toml" <<'PYEOF'
import pathlib, re, sys
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
starts = [i for i, l in enumerate(lines) if l.strip() == "[[projects]]"]
s = starts[1]
seg = "\n".join(lines[s:s + 30])
bad = [k for k in ("admin_from", "allow_from") if k in seg]
print("  ✅ claude 区块没被碰(两个键都没出现)" if not bad else f"  ❌ claude 区块被改了: {bad}")
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || FAIL=1
echo

# ---------- 5. 换一个 id:值必须被整体替换,而不是追加 ----------
echo "══ 5. 改 open_id 时替换而不是追加 ══"
ID_L2="ou_ffffffffffffffffffffffffffffffff"
run_patch --codex "$ID_C" --claude "$ID_L2" > "$VD/r5.log" 2>&1
[ "$(grep -c "$ID_L2" "$SB/config.toml")" = "2" ] && ok "新 id 出现 2 次(admin + allow)" || fail "新 id 出现次数不对"
[ "$(grep -c "$ID_L" "$SB/config.toml")" = "0" ] && ok "旧 id 已被完全替换" || fail "旧 id 还留着"
[ "$(grep -c "$ID_C" "$SB/config.toml")" = "2" ] && ok "没被点名的 codex 保持原值" || fail "codex 被连累了"
echo

# ---------- 6. project 名对不上时必须整体放弃 ----------
echo "══ 6. config.toml 里没有这个 project 时,原文件不动 ══"
mk_config
BEFORE="$(md5sum "$SB/config.toml" | awk '{print $1}')"
run_patch --codex "$ID_C" --claude "$ID_L" >/dev/null 2>&1   # 先写一次正常的
BEFORE="$(md5sum "$SB/config.toml" | awk '{print $1}')"
bash "$HERE/make-whitelist-cmd.sh" --codex "$ID_C" --gemini "$ID_L" >/dev/null 2>&1 \
    && fail "未知 project 名竟然被接受" || ok "未知 project 名被拒"
# 把 claude 那个 project 整段删掉,再点名 claude:应失败且文件不动
"$PY" - <<PYEOF
import pathlib
p = pathlib.Path(r"$(w "$SB")/config.toml")
t = p.read_text(encoding="utf-8")
p.write_text(t[:t.index('[[projects]]\nname = "claude"')].rstrip() + "\n", encoding="utf-8")
PYEOF
BEFORE="$(md5sum "$SB/config.toml" | awk '{print $1}')"
run_patch --codex "$ID_C" --claude "$ID_L" > "$VD/r6.log" 2>&1
[ "$(md5sum "$SB/config.toml" | awk '{print $1}')" = "$BEFORE" ] \
    && ok "点名了不存在的 claude,原文件一个字节没动" || fail "自检没拦住,文件被改了"
grep -q '没有这些 project: claude' "$VD/r6.log" && ok "报错点明了是哪个 project 缺失" || fail "报错没说清缺哪个"
echo

# ---------- 7. 命令体必须纯 ASCII ----------
echo "══ 7. 命令体纯 ASCII(剪贴板只认 ASCII) ══"
bash "$HERE/make-whitelist-cmd.sh" --codex "$ID_C" --claude "$ID_L" > "$VD/gen.out" 2>&1
"$PY" - "$(w "$VD")/gen.out" <<'PYEOF'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
marker = "=== 下面这一整行就是命令(已复制到剪贴板,粘给原命令机器人) ==="
if marker not in lines:
    print("  FAIL 提示行文案变了,取不到命令体"); sys.exit(1)
bad = [hex(ord(c)) for c in lines[lines.index(marker) + 1] if ord(c) > 127]
print("  OK 命令体全是 ASCII" if not bad else f"  FAIL 含非 ASCII: {bad}")
sys.exit(1 if bad else 0)
PYEOF
[ $? = 0 ] || FAIL=1
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
