#!/bin/bash
# 本地验证 make-upload-cmd.sh 的 gzip + 分片上传
#
# 关键点:不能只看它"打印了什么",要把生成的命令**真的执行一遍**,
# 再比对 md5 —— 上传命令错了的代价是容器里得到一个半截文件,
# 而那种错在飞书里表现为"机器人行为诡异",极难回推到上传环节。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VD="$HERE/.verify-upload"
SB="$VD/sb"
PY="${PY:-python}"
export PYTHONUTF8=1

rm -rf "$VD"
mkdir -p "$SB"

FAIL=0
fail() { echo "  ❌ $1"; FAIL=1; }
ok()   { echo "  ✅ $1"; }

# ---------- 1. 语法 ----------
echo "══ 1. 静态检查 ══"
bash -n "$HERE/make-upload-cmd.sh" && ok "语法通过" || fail "语法错误"
echo

# 从脚本输出里抠出待执行的命令,逐条跑掉,最后比 md5
# $1=源文件 $2=沙盒目标 $3=场景名
run_case() {
    local src="$1" dst="$2" name="$3"
    local out="$VD/$name.out"
    bash "$HERE/make-upload-cmd.sh" "$src" "$dst" > "$out" 2>&1
    local rc=$?
    [ "$rc" = "0" ] || { fail "$name: 生成退出码 $rc"; return; }

    local expect_md5; expect_md5="$(md5sum "$src" | cut -d' ' -f1)"
    local expect_size; expect_size="$(wc -c < "$src" | tr -d ' ')"

    "$PY" - "$out" > "$VD/$name.cmds" <<'PYEOF'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lines = []
# 单条模式:命令在"下面这一整行就是命令"和"容器里执行成功后"之间
m = re.search(r"=== 下面这一整行就是命令.*?\n\n(.*?)\n\n=== 容器里执行成功后", text, re.S)
if m:
    lines = [m.group(1)]
else:
    # 分片模式:每个 "----- 第 N/M 片 -----" 之后的第一行
    for blk in re.findall(r"----- 第 \d+/\d+ 片 -----\n(.*?)\n", text):
        lines.append(blk)
for ln in lines:
    print(ln)
PYEOF

    local n; n="$(wc -l < "$VD/$name.cmds" | tr -d ' ')"
    [ "$n" -ge 1 ] || { fail "$name: 没抠出任何命令"; return; }

    if grep -q "分片" "$out"; then
        echo "  ── $name: 分片模式,$n 片 ──"
    else
        echo "  ── $name: 单条模式 ──"
    fi
    # 逐条执行(模拟"依次粘到容器里")
    local i=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if ! bash -c "$line" >> "$VD/$name.exec" 2>&1; then
            fail "$name: 第 $((i+1)) 条命令执行失败"
            tail -3 "$VD/$name.exec" | sed 's/^/     /'
            return
        fi
        i=$((i+1))
    done < "$VD/$name.cmds"

    if [ ! -f "$dst" ]; then
        fail "$name: 目标文件没生成"; return
    fi
    local got_md5 got_size
    got_md5="$(md5sum "$dst" | cut -d' ' -f1)"
    got_size="$(wc -c < "$dst" | tr -d ' ')"
    [ "$got_md5" = "$expect_md5" ] && [ "$got_size" = "$expect_size" ] \
        && ok "$name: 往返一致($got_size 字节,$got_md5)" \
        || fail "$name: md5/字节数不符 —— 期望 $expect_size/$expect_md5,实得 $got_size/$got_md5"
    # 临时文件不能留
    [ -f "$dst.b64" ] && fail "$name: .b64 临时文件没清掉" || true
    [ -f "$dst.new" ] && fail "$name: .new 临时文件没清掉" || true
}

# ---------- 2. 小文件(单条模式) ----------
echo "══ 2. 小文件走单条模式 ══"
printf 'CODEX_KEY=sk-test\nCODEX_MODEL=gpt-5.6-sol\n' > "$SB/small.env"
run_case "$SB/small.env" "$SB/out-small.env" small
echo

# ---------- 3. 大文件(分片模式) ----------
echo "══ 3. 大文件走分片模式 ══"
# 造一个和真实 provider 片段同量级的文件:重复但内容不完全相同,
# 保证压缩率真实(全同内容会被压成极小,测不到分片路径)。
# 体量要压出 ≥3 片,否则第 5 节"漏发中间片"根本凑不出中间片来测。
"$PY" - "$SB/big.toml" <<'PYEOF'
import pathlib, sys
out = []
for i in range(700):
    out.append(f"""  [[projects.agent.providers]]
    name = "relay{i}"
    api_key = "sk-fake-{i:04d}-{'x' * 24}"
    base_url = "https://relay{i}.example/v1"
    model = "gpt-5.6-sol-{i}"
    [[projects.agent.providers.models]]
      model = "gpt-5.6-sol-{i}"
      alias = "sol{i}\"""")
pathlib.Path(sys.argv[1]).write_text("\n\n".join(out) + "\n", encoding="utf-8")
PYEOF
SZ=$(wc -c < "$SB/big.toml" | tr -d ' ')
echo "  测试文件 $SZ 字节"
run_case "$SB/big.toml" "$SB/out-big.toml" big
# 分片模式下 .bak 不该存在(原文件本来就不在),但内容必须完整
[ -s "$SB/out-big.toml" ] && ok "大文件内容非空" || fail "大文件落盘为空"
echo

# ---------- 4. 分片命令本身必须短到能发出去 ----------
echo "══ 4. 每片长度都在单条消息上限内 ══"
if [ -f "$VD/big.cmds" ]; then
    MAXLEN=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$VD/big.cmds")
    if [ "$MAXLEN" -lt 8192 ]; then
        ok "最长一片 $MAXLEN 字符(< 8192)"
    else
        fail "最长一片 $MAXLEN 字符,超过单条上限"
    fi
else
    fail "没有分片命令可测"
fi
echo

# ---------- 5. 缺片必须能被发现 ----------
# 分片命令里的目标路径是写死的,所以重放前必须把抽出来的命令改成另一个目标 ——
# 否则重放的是第 3 节那个 out-big.toml,而断言盯着 out-big2.toml,就成了
# "对着一个没人写过的文件做断言":永远通过,却什么都没测到。
echo "══ 5. 漏发中间片时必须当场中止,且不落盘 ══"
rm -f "$SB/out-big2.toml" "$SB/out-big2.toml.b64"
sed 's#out-big\.toml#out-big2.toml#g' "$VD/big.cmds" > "$VD/big2.cmds"
TOTAL=$(wc -l < "$VD/big2.cmds" | tr -d ' ')
if [ "$TOTAL" -ge 3 ]; then
    i=0
    while IFS= read -r line; do
        i=$((i+1))
        [ "$i" = "2" ] && continue          # 故意跳过中间那一片
        bash -c "$line" > "$VD/miss.out" 2>&1 || true
    done < "$VD/big2.cmds"
    if [ -f "$SB/out-big2.toml" ]; then
        A=$(md5sum "$SB/big.toml" | cut -d' ' -f1)
        B=$(md5sum "$SB/out-big2.toml" | cut -d' ' -f1)
        [ "$A" != "$B" ] && ok "缺片时 md5 确实对不上(能被发现)" || fail "缺片竟然还原成功"
    elif grep -q 'aborted' "$VD/miss.out" && grep -q 'Target file untouched' "$VD/miss.out"; then
        ok "漏发中间片时下一片当场中止,且说明了目标文件没被动"
    else
        fail "缺片后既没报错也没落盘 —— 静默失败最难查"; sed 's/^/     /' "$VD/miss.out" | tail -3
    fi
else
    echo "  ➖ 跳过(本次只有 $TOTAL 片,凑不出中间的片)"
fi
echo

# ---------- 6. --no-split:大文件也只出一条命令 ----------
# 平台 Web 终端没有 8192 限制,切片只会让人多粘几次。这条路径要保证:
# 输出恒为一条命令,且执行后 md5 与源文件一致。
echo "══ 6. --no-split:大文件也只出一条命令 ══"
NS="$SB/out-ns.toml"
rm -f "$NS" "$NS.b64"
bash "$HERE/make-upload-cmd.sh" "$SB/big.toml" "$NS" --no-split > "$VD/ns.out" 2>&1 \
    || fail "生成失败"
# 注意:头部元信息里有"不分片"三个字,所以判分片要看切片标记,不能 grep "分片"
if grep -q -- '----- 第 ' "$VD/ns.out"; then
    fail "--no-split 仍然切片了"
else
    ok "未切片"
fi
"$PY" - "$VD/ns.out" > "$VD/ns.cmd" <<'PYEOF'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"=== 下面这一整行就是命令.*?\n\n(.*?)\n\n=== 容器里执行成功后", text, re.S)
print(m.group(1) if m else "")
PYEOF
if [ ! -s "$VD/ns.cmd" ]; then
    fail "没抠出命令"
else
    NLEN=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$VD/ns.cmd")
    ok "整条命令 $NLEN 字符(超过 8192 也仍是一条)"
    bash -c "$(cat "$VD/ns.cmd")" >/dev/null 2>&1 || fail "执行失败"
    A=$(md5sum "$SB/big.toml" | cut -d' ' -f1)
    B=$(md5sum "$NS" | cut -d' ' -f1)
    [ "$A" = "$B" ] && ok "往返一致($A)" || fail "md5 不符: 期望 $A 实得 $B"
    [ -f "$NS.b64" ] && fail ".b64 临时文件没清掉" || true
    [ -f "$NS.new" ] && fail ".new 临时文件没清掉" || true
fi
echo

# ---------- 7. --copy N:只放剪贴板,不打印命令体 ----------
# 命令体本身就是密钥,打印出来等于把密钥铺满一屏。这一段要保证三件事:
# ① --copy N 的 stdout 里没有命令体;② N 越界要报错;③ 放进去的真是第 N 片。
echo "══ 7. --copy N 只放剪贴板,不打印命令体 ══"
CLIP=""
if command -v clip.exe >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
    CLIP=1
    # 本节会改写剪贴板,先把用户原来的存下来,收尾还回去
    printf '%s' "$(powershell.exe -NoProfile -Command 'Get-Clipboard -Raw' 2>/dev/null)" > "$VD/clip.saved"
fi

# 期望值必须用**同一个目标路径**的默认输出取,否则两个 out 文件里的目标名不一样,
# 比的就成了文件名而不是片号。默认模式自己会把第 1 片写进剪贴板,所以它必须先跑,
# 再跑 --copy 2 —— 顺序反过来,读到的就是被顶掉的第 1 片。
bash "$HERE/make-upload-cmd.sh" "$SB/big.toml" "$SB/out-copy.toml" > "$VD/copydflt.out" 2>&1
# 片数从输出里数出来,不写死 —— 测试文件一变大小,写死的"第 2/2 片"就永远抠不到,
# 而 EXPECT 空掉之后下面那句比对会变成"拿空串和剪贴板比",报的错牛头不对马嘴。
NCH=$(grep -c -- '----- 第 ' "$VD/copydflt.out")
[ "$NCH" -ge 2 ] || fail "默认输出里只有 $NCH 片,凑不出第 2 片做基准"
EXPECT="$(sed -n "/----- 第 2\/$NCH 片 -----/{n;p;}" "$VD/copydflt.out" | tr -d '\r\n')"
[ -n "$EXPECT" ] && ok "默认输出里有第 2/$NCH 片(${#EXPECT} 字符),可作比对基准" || fail "默认输出里没抠到第 2 片"

bash "$HERE/make-upload-cmd.sh" "$SB/big.toml" "$SB/out-copy.toml" --copy 2 > "$VD/copy2.out" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "--copy 2 正常退出" || { fail "--copy 2 退出码 $RC"; tail -3 "$VD/copy2.out"; }
# 头部元信息都是短行(最长的那行是"容器里执行成功后…核对").命令体是几千字符,
# 所以"最长行 < 200"就等价于"没有命令体被打印出来"。
MAXLEN=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$VD/copy2.out")
if [ "$MAXLEN" -lt 200 ]; then
    ok "输出里没有命令体(最长行 $MAXLEN 字符)"
else
    fail "--copy 2 把命令体打了出来(最长行 $MAXLEN 字符)"
fi
grep -q "第 2/$NCH 条已放进剪贴板" "$VD/copy2.out" && ok "提示了放的是第 2/$NCH 条" || fail "没提示片号"

# 片号选对了没有,只有把剪贴板读回来才能证明。读不到就明说跳过,
# 不用"没报错"冒充"验证过"。
if [ -n "$CLIP" ]; then
    GOT="$(powershell.exe -NoProfile -Command 'Get-Clipboard -Raw' 2>/dev/null | tr -d '\r\n')"
    if [ -z "$GOT" ]; then
        echo "  ➖ 剪贴板读不到内容,跳过片号比对"
    elif [ "$GOT" = "$EXPECT" ]; then
        ok "剪贴板里确实是第 2 片(${#GOT} 字符)"
    else
        fail "剪贴板内容不是第 2 片(期望 ${#EXPECT} 字符,实得 ${#GOT} 字符)"
    fi
else
    echo "  ➖ 无 clip.exe / powershell.exe,跳过片号比对(手动粘一次即可确认)"
fi

for bad in 0 $(( NCH + 1 )) 99; do
    bash "$HERE/make-upload-cmd.sh" "$SB/big.toml" "$SB/out-copy.toml" --copy "$bad" > "$VD/copybad.out" 2>&1
    RC=$?
    if [ "$RC" != "0" ] && grep -q '越界' "$VD/copybad.out"; then
        ok "--copy $bad 越界被拒绝"
    else
        fail "--copy $bad 没被拒绝(退出码 $RC)"
    fi
done
# 忘了写序号的写法也要拦下,不能默默把它当成默认(放第 1 片)
bash "$HERE/make-upload-cmd.sh" "$SB/big.toml" "$SB/out-copy.toml" --copy > "$VD/copynone.out" 2>&1
[ $? != "0" ] && ok "--copy 缺序号被拒绝" || fail "--copy 缺序号没被拦下"

[ -n "$CLIP" ] && { printf '%s' "$(cat "$VD/clip.saved")" | clip.exe 2>/dev/null && ok "原有剪贴板已还原"; }
echo

# ---------- 8. 缺片重放不能清空已有目标文件 ----------
# 现场事故:上传完成后 .b64 已被 rm 掉,此时若把最后一片**单独**再发一次
# (比如剪贴板里还留着上次的命令),它会新建一个只含半截 base64 的 .b64,
# 解出来不是 gzip;而 `> $DST` 的截断发生在 gunzip 之前 —— 目标文件被清空,
# 现场只留一句 "not in gzip format"。这一段就把这个场景钉死。
# 目标必须是 big.cmds 真正写入的那个路径,换成别的等于测空气。
echo "══ 8. 缺片重放必须中止,且不动已有目标文件 ══"
R8="$SB/out-big.toml"
A=$(md5sum "$SB/big.toml" | cut -d' ' -f1)
B=$(md5sum "$R8" 2>/dev/null | cut -d' ' -f1)
if [ "$A" = "$B" ]; then
    ok "第 3 节留下的目标文件是好的($A),可以开始重放实验"
    rm -f "$R8.b64"                        # 模拟"上传成功后 .b64 已被清掉"
    bash -c "$(tail -1 "$VD/big.cmds")" > "$VD/replay2.out" 2>&1
    RC=$?
    C=$(md5sum "$R8" 2>/dev/null | cut -d' ' -f1)
    [ "$RC" != "0" ] && ok "单独重放最后一片被拦下(退出码 $RC)" \
        || fail "单独重放最后一片没被拦下 —— 已有文件会被清空"
    grep -q 'aborted' "$VD/replay2.out" && grep -q 'Target file untouched' "$VD/replay2.out" \
        && ok "报错说清了原因和影响面" || { fail "没有可读的中止提示"; sed 's/^/     /' "$VD/replay2.out"; }
    [ "$C" = "$A" ] && ok "目标文件原封不动($C)" \
        || fail "目标文件被改坏了: 期望 $A 实得 ${C:-<空>}"
    [ -f "$R8.new" ] && fail "留下了半截 .new 文件" || ok "也没留下半截 .new"
else
    fail "第 3 节的目标文件不是好的(${B:-<空>}),重放实验无法进行"
fi
echo

# ---------- 9. 命令体必须是纯 ASCII ----------
# 命令是经 Windows 剪贴板(clip.exe 按 OEM 代码页转码)交到用户手里的。实测中文和
# emoji 都会在这一步变成 U+FFFD,而且时好时坏 —— 命令本身还能跑,但提示文字变乱码,
# 现场表现为"看不懂的报错",几乎不可能回推到剪贴板。非 ASCII 一律当错误卡住。
echo "══ 9. 命令体必须是纯 ASCII(剪贴板只认 ASCII) ══"
"$PY" - "$VD/small.cmds" "$VD/big.cmds" "$VD/ns.cmd" <<'PYEOF'
import pathlib, sys
bad = []
for name in sys.argv[1:]:
    p = pathlib.Path(name)
    if not p.exists():
        continue
    for ch in sorted({c for c in p.read_text(encoding="utf-8") if ord(c) > 127}):
        bad.append(f"{p.name}: {ch!r} U+{ord(ch):04X}")
if bad:
    print("  ❌ 命令体里有非 ASCII 字符,过剪贴板会变成乱码:")
    for b in bad:
        print(f"     - {b}")
    sys.exit(1)
print("  ✅ 命令体全是 ASCII,剪贴板可无损传递")
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
