#!/bin/bash
# 验证 bootstrap.sh:判台 / 取文件 / 铺进去 / 报告 四条行为,以及"不碰配置"这条底线
#
# 为什么必须验它:
#   bootstrap.sh 是容器重建后**第一个**跑的脚本。它出问题的时候,正好是本机到
#   容器最缺通道的时候(没有直达 shell,只能靠飞书转述),所以每条分支都要在本机
#   先跑通,不能等到现场。
#
# ── 已知覆盖缺口(写在这里,别当成已验) ──────────────────────────────
#   1. 判台的标记路径在容器里是写死的 /workspace/run-new-api.sh,本机造不出来
#      (那是项目外的系统目录,不能写)。故用 sed 把路径替换到沙盒里,验的是
#      **判断逻辑**,不是字面路径 —— 容器里的真实路径要靠第 1 次实跑确认。
#   2. 不验 mktemp 失败分支(无法可靠构造)。
#   3. 第 6 节要联网拉 GitHub。离线、或仓库还没推时自动跳过并明说,不假装通过。

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/bootstrap.sh"
SB="$HERE/.verify-bootstrap"

[ -f "$SRC" ] || { echo "❌ 找不到 $SRC"; exit 1; }

pass=0
fail=0
ok()  { printf '  ✅ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ❌ %s\n' "$*"; fail=$((fail + 1)); }

rm -rf "$SB"
mkdir -p "$SB"

echo "══ 1. 语法检查 ══"
if bash -n "$SRC" 2>"$SB/syntax.err"; then
  ok "bash -n 通过"
else
  bad "bash -n 失败:"; cat "$SB/syntax.err"
  echo; echo "语法都不过,后面的用例没有意义,停。"; exit 1
fi

echo
echo "══ 2. 干净沙盒:应该铺脚本 + 报缺 bots.env ══"
WS="$SB/ws"
mkdir -p "$WS"
out="$(CC_DIR="$WS" bash "$SRC" 2>&1)"; rc=$?

[ "$rc" -eq 0 ] && ok "退出码 0" || bad "退出码 $rc(期望 0)"

n_sh=$(find "$WS" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d ' ')
[ "$n_sh" -ge 10 ] && ok "铺进 $n_sh 个 .sh" || bad "只铺进 $n_sh 个 .sh"

[ -f "$WS/restore-all.sh" ]     && ok "restore-all.sh 到位"     || bad "缺 restore-all.sh"
[ -f "$WS/set-heartbeat.py" ]   && ok "set-heartbeat.py 到位"   || bad "缺 set-heartbeat.py"
[ -f "$WS/skills/feishu-send/SKILL.md" ] \
  && ok "skills/feishu-send/SKILL.md 跟到位" \
  || bad "skills/ 没跟过去(make-skill-cmd.sh 会指向不存在的文件)"

# 可执行位:restore-all.sh 要能直接 bash 跑,其余脚本靠 chmod +x
[ -x "$WS/restore-all.sh" ] && ok "restore-all.sh 有可执行位" || bad "restore-all.sh 没有可执行位"

printf '%s' "$out" | grep -q '缺 bots.env' \
  && ok "报告里有「缺 bots.env」" || bad "报告里没提 bots.env"
printf '%s' "$out" | grep -q 'restore-all.sh' \
  && ok "报告里给了 restore-all.sh 这条命令" || bad "报告里没给出下一步命令"

# 关键底线:bootstrap 不许自己造配置
for f in bots.env config.toml run.sh; do
  [ -e "$WS/$f" ] && bad "bootstrap 擅自造了 $f(这是刻意的留白,不能补)" \
                  || ok "没有擅自造 $f"
done

echo
echo "══ 3. 配置齐全:应该说「配置齐了」 ══"
WS2="$SB/ws-full"
mkdir -p "$WS2"
printf '哨兵:bots.env 不能被碰\n' > "$WS2/bots.env"
printf '哨兵:config.toml 不能被碰\n' > "$WS2/config.toml"
printf '哨兵:run.sh 不能被碰\n'      > "$WS2/run.sh"

out2="$(CC_DIR="$WS2" bash "$SRC" 2>&1)"; rc2=$?
[ "$rc2" -eq 0 ] && ok "退出码 0" || bad "退出码 $rc2"

printf '%s' "$out2" | grep -q '配置齐了' \
  && ok "报告说「配置齐了」" || bad "配置齐全时没给出「配置齐了」"

# 幂等 + 不覆盖:重跑一次,已有的三个文件内容必须原样
before="$(md5sum "$WS2/bots.env" "$WS2/config.toml" "$WS2/run.sh" | awk '{print $1}' | tr '\n' ' ')"
CC_DIR="$WS2" bash "$SRC" >/dev/null 2>&1
after="$(md5sum "$WS2/bots.env" "$WS2/config.toml" "$WS2/run.sh" | awk '{print $1}' | tr '\n' ' ')"
[ "$before" = "$after" ] && ok "重跑后 bots.env/config.toml/run.sh 原样未动" \
                         || bad "重跑把已有配置改了(before=$before after=$after)"

# 反向:光有 bots.env、没有 config.toml 时,不该说"齐了"
WS3="$SB/ws-partial"
mkdir -p "$WS3"
printf 'x\n' > "$WS3/bots.env"
out3="$(CC_DIR="$WS3" bash "$SRC" 2>&1)"
printf '%s' "$out3" | grep -q '配置齐了' \
  && bad "只有 bots.env 就报「齐了」—— 漏判 config.toml/run.sh" \
  || ok "只有 bots.env 时不报「齐了」"
printf '%s' "$out3" | grep -q 'deploy-codex.sh' \
  && ok "提示了 deploy-codex.sh" || bad "没提示 deploy-codex.sh"

echo
echo "══ 4. 判台:认成腾讯容器必须硬停 ══"
# 把脚本里写死的 /workspace 换到沙盒,验判断逻辑(见文件头「已知覆盖缺口」第 2 条)。
# 副本必须落在一个**像仓库的目录**里($SB/repo,含 restore-all.sh 等),否则脚本会走
# 下载分支 —— 仓库还没推,那样验到的是网络失败,不是判台。
GUARD="$SB/guard"
mkdir -p "$GUARD"
REPOCOPY="$SB/repo"
mkdir -p "$REPOCOPY"
cp -f "$HERE"/*.sh "$HERE"/*.py "$REPOCOPY"/
[ -d "$HERE/skills" ] && cp -R "$HERE/skills" "$REPOCOPY"/
sed "s#/workspace#$GUARD#g" "$SRC" > "$REPOCOPY/bootstrap.sh"
GUARD_SH="$REPOCOPY/bootstrap.sh"

: > "$GUARD/run-new-api.sh"          # 腾讯那台的标志文件

outg="$(bash "$GUARD_SH" 2>&1)"; rcg=$?
[ "$rcg" -ne 0 ] && ok "认出腾讯容器,退出码 $rcg(非 0)" || bad "认出腾讯容器却没有非 0 退出"
printf '%s' "$outg" | grep -q '腾讯' \
  && ok "报错文案点明了是腾讯那台" || bad "报错文案没说清是哪台"
printf '%s' "$outg" | grep -q 'MONKEYCODE_OPS_FORCE' \
  && ok "给了强行继续的开关" || bad "没给强行继续的开关"

# 反向:没有标志文件时,同一个脚本不该被拦
rm -f "$GUARD/run-new-api.sh"
CC_DIR="$SB/ws-guard-ok" bash "$GUARD_SH" >/dev/null 2>&1
[ $? -eq 0 ] && ok "标志文件不在时不被拦(照常铺)" || bad "没标志文件也被拦了 —— 判台条件写反了"

# 重新放回标志文件,这次带 FORCE=1 —— 应放行并明确提示"守卫被绕过",而不是默默继续
: > "$GUARD/run-new-api.sh"
outf="$(MONKEYCODE_OPS_FORCE=1 CC_DIR="$SB/ws-guard-force" bash "$GUARD_SH" 2>&1)"; rcf=$?
[ "$rcf" -eq 0 ] && ok "FORCE=1 时不再硬停(退出码 0)" || bad "FORCE=1 仍被拦(退出码 $rcf)"
printf '%s' "$outf" | grep -q '❌' \
  && bad "FORCE=1 后仍打判台的 ❌ 报错" || ok "FORCE=1 后不再打 ❌ 报错"
printf '%s' "$outf" | grep -q 'FORCE=1,按你说的继续' \
  && ok "FORCE=1 后明确提示守卫被绕过" || bad "FORCE=1 绕过了守卫却没提示(用户会以为判过台了)"
[ -f "$SB/ws-guard-force/restore-all.sh" ] \
  && ok "FORCE=1 时确实继续铺了文件" || bad "FORCE=1 时没有铺文件"

echo
echo "══ 5. 自身不含密钥 ══"
# bootstrap.sh 会被推到公开仓库,里面绝不能有真实凭证
if grep -nE '(sk-[A-Za-z0-9]{16,}|app_secret *= *[A-Za-z0-9]{16,})' "$SRC" >/dev/null 2>&1; then
  bad "bootstrap.sh 里出现疑似真实密钥"
else
  ok "bootstrap.sh 无真实密钥模式"
fi

echo
echo "══ 6. 端到端:拉真实 URL 跑下载分支(需联网) ══"
# 前 5 节验的都是"就地取文件"分支,而容器里走的却是**下载分支** —— 那条路只有当
# 仓库真推到 GitHub 之后才验得了,偏偏它最不能出错(容器重建时没有别的退路)。
# 所以这里拉真实 raw URL、走真实 tarball 端点跑一遍。
DL="$SB/dl"
E2E="$SB/e2e"
rm -rf "$DL" "$E2E"
mkdir -p "$DL" "$SB/tmp" "$E2E"

if ! curl -fsSL --max-time 30 \
     "https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/bootstrap.sh" \
     -o "$DL/bootstrap.sh" 2>/dev/null; then
  echo "  ⏭️  拉不到(离线或仓库未推)—— 本节跳过,它**没有**通过,别当成验过"
else
  [ "$(md5sum < "$SRC")" = "$(md5sum < "$DL/bootstrap.sh")" ] \
    && ok "远端 bootstrap.sh 与本地内容一致" \
    || bad "远端 bootstrap.sh 与本地不一致(是不是忘了 push?)"

  # 行尾必须是 LF。这里**不要**写 grep -c $'\r' —— git bash 上 $'\r' 会展开成
  # 空串,等价于 grep -c ''(匹配每一行),必然误报成"每行都带 CR"。改用字节计数。
  if PYTHONIOENCODING=utf-8 python -c "
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
sys.exit(1 if b.count(b'\r') else 0)" "$DL/bootstrap.sh"; then
    ok "远端 bootstrap.sh 无 CR 字节(纯 LF)"
  else
    bad "远端 bootstrap.sh 含 CR —— 容器里会变成 \r: command not found"
  fi

  # 真跑下载分支:该目录里没有 restore-all.sh,必然走 tarball。
  # TMPDIR 必须指到项目内,否则 mktemp -d 会写到项目外的系统临时目录。
  # 注意 $SB 已经是绝对路径($HERE/.verify-bootstrap),别再套 $PWD。
  out6="$(TMPDIR="$SB/tmp" CC_DIR="$E2E" bash "$DL/bootstrap.sh" 2>&1)"; rc6=$?
  [ "$rc6" -eq 0 ] && ok "下载分支跑通(退出码 0)" || bad "下载分支退出码 $rc6"
  [ -f "$E2E/restore-all.sh" ] \
    && ok "tarball 里的脚本落到位" || bad "tarball 没铺出脚本"
  [ -f "$E2E/skills/feishu-send/SKILL.md" ] \
    && ok "tarball 里的 skills/ 落到位" || bad "tarball 没铺出 skills/"
  printf '%s' "$out6" | grep -q '缺 bots.env' \
    && ok "下载分支也正确报告了缺失项" || bad "下载分支没报告缺失项"

  # 砂盒临时目录跑完应为空:非空说明 mktemp 没走 TMPDIR,可能写到了项目外
  if [ -n "$(ls -A "$SB/tmp" 2>/dev/null)" ]; then
    bad "砂盒临时目录非空 —— mktemp 可能写到了项目外"
  else
    ok "mktemp 全程落在项目内(TMPDIR 生效)"
  fi
fi

echo
echo "════════════════════════════════════════"
printf '通过 %d,失败 %d\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
  echo "✅ 全部断言通过"
else
  echo "❌ 有失败项"
  exit 1
fi
