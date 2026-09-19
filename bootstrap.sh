#!/bin/bash
# MonkeyCode 容器重建后,把本仓库的脚本铺进 /workspace/cc-connect/
#
# 用法一(容器里还什么都没有,一条命令):
#     curl -fsSL https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/bootstrap.sh | bash
# 用法二(已经把本仓库 clone/解压到容器里了):
#     bash bootstrap.sh
#
# ── 它做什么 ──────────────────────────────────────────────────────
#   [1/4] 判台    —— 认成另一台容器(腾讯 icgsqq)就直接停,不往下做
#   [2/4] 取文件  —— 就地取,取不到就下 tarball
#   [3/4] 铺进去  —— *.sh / *.py / skills/ 刷进 /workspace/cc-connect/
#   [4/4] 报告    —— 列出还缺哪些配置、下一步跑哪个脚本
#
# ── 它不做什么(刻意留白) ─────────────────────────────────────────
#   不生成 config.toml / run.sh / bots.env:
#     · 前两个由 deploy-codex.sh 生成,那一步还会跑冒烟测试;
#     · bots.env 含真实飞书凭证与 provider key,只能从本机送进来。
#   bootstrap 凭猜造出来的配置,只会把问题掩盖成更难查的故障。
#
# ── 幂等 ──────────────────────────────────────────────────────────
#   重复跑只把脚本刷成当前版本;不碰 config.toml / run.sh / bots.env,
#   也不启停任何进程。铺完不会自动拉起服务,由你确认后自己跑 restore-all.sh。

set -uo pipefail

REPO="${MONKEYCODE_OPS_REPO:-Eitan-S-23/monkeycode-ops}"
BRANCH="${MONKEYCODE_OPS_BRANCH:-main}"
CC_DIR="${CC_DIR:-/workspace/cc-connect}"

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ── [1/4] 判台 ────────────────────────────────────────────────────
# 本机运维着**两台互不相通的容器**,操作通道和代价完全不同。这台是 MonkeyCode
# (标志:/workspace/cc-connect、/workspace/cpa);另一台是腾讯 Cloud Studio
# icgsqq(跑 new-api,标志:/workspace/run-new-api.sh,以及单文件 feishu-bot.py)。
#
# 认错了**不会报错,只会白忙** —— 所以这里硬停,不要"先跑一下看看"。
# 反过来:如果 cc-connect 目录已存在,那就没认错,直接放行。
if [ ! -d "$CC_DIR" ]; then
  hit=""
  [ -f /workspace/run-new-api.sh ] && hit="/workspace/run-new-api.sh"
  [ -z "$hit" ] && [ -f /workspace/feishu-bot.py ] && hit="/workspace/feishu-bot.py(单文件)"
  if [ -n "$hit" ]; then
    if [ "${MONKEYCODE_OPS_FORCE:-}" = "1" ]; then
      say "⚠️  发现了 $hit —— 看着像腾讯那台,但 MONKEYCODE_OPS_FORCE=1,按你说的继续。"
    else
      say "❌ 这看起来是【腾讯 Cloud Studio icgsqq】那台容器,不是 MonkeyCode。"
      say "   证据:发现了 $hit"
      say "   本仓库的脚本装到那台上没有意义,两边的操作通道也不同,会白烧额度。"
      say "   分不清时读 container-map skill。确实要强行继续:"
      say "     MONKEYCODE_OPS_FORCE=1 bash bootstrap.sh"
      exit 1
    fi
  fi
fi

# ── [2/4] 取文件 ──────────────────────────────────────────────────
STAGE="$(mktemp -d)" || die "建不出临时目录"
trap 'rm -rf "$STAGE"' EXIT

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/restore-all.sh" ]; then
  say "▸ [2/4] 就地取文件:$SELF_DIR"
  # 只取要装的那几类,不整目录拷 —— 本机那份里有 .cache/(20MB 上游克隆)等噪声
  cp -f "$SELF_DIR"/*.sh "$STAGE"/ 2>/dev/null
  cp -f "$SELF_DIR"/*.py "$STAGE"/ 2>/dev/null
  [ -d "$SELF_DIR/skills" ] && cp -R "$SELF_DIR/skills" "$STAGE"/
  [ -f "$SELF_DIR/README.md" ] && cp -f "$SELF_DIR/README.md" "$STAGE"/
else
  command -v curl >/dev/null 2>&1 || die "没有 curl,也没在仓库目录里跑 —— 取不到文件"
  command -v tar  >/dev/null 2>&1 || die "没有 tar,解不开 tarball"
  say "▸ [2/4] 下载 $REPO ($BRANCH)"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
    | tar xz -C "$STAGE" --strip-components=1 \
    || die "下载或解压失败 —— 仓库是否已推到 $REPO 的 $BRANCH 分支?"
fi

[ -f "$STAGE/restore-all.sh" ] || die "取到的文件里没有 restore-all.sh,不敢继续铺"

# ── [3/4] 铺进去 ──────────────────────────────────────────────────
mkdir -p "$CC_DIR" || die "建不出 $CC_DIR"

copied=0
for f in "$STAGE"/*.sh "$STAGE"/*.py; do
  [ -f "$f" ] || continue
  cp -f "$f" "$CC_DIR/" && copied=$((copied + 1))
done
chmod +x "$CC_DIR"/*.sh "$CC_DIR"/*.py 2>/dev/null

# skills/ 必须跟着走:make-skill-cmd.sh 按 $HERE/skills/feishu-send/SKILL.md 找它,
# 少了它生成的安装命令会指向不存在的文件。
if [ -d "$STAGE/skills" ]; then
  cp -Rf "$STAGE/skills" "$CC_DIR/"
  say "▸ [3/4] 已铺 $copied 个脚本 + skills/ 到 $CC_DIR"
else
  say "▸ [3/4] 已铺 $copied 个脚本到 $CC_DIR(警告:没取到 skills/)"
fi

# ── [4/4] 报告还缺什么 ────────────────────────────────────────────
# 顺序是有讲究的:deploy-codex.sh 的第一件事就是读 bots.env,缺了它会直接报错,
# 所以 bots.env 必须排在前面 —— 不能只列"缺什么",要给出先后。
say ""
say "── 还缺什么 ──────────────────────────────────────────────"

blockers=0
if [ ! -f "$CC_DIR/bots.env" ]; then
  say "① 缺 bots.env —— 含飞书 App 凭证与 provider key,仓库里刻意没有。"
  say "   在本机生成后送进 $CC_DIR/(README「密钥从哪来」)。"
  blockers=1
fi
if [ ! -f "$CC_DIR/config.toml" ] || [ ! -f "$CC_DIR/run.sh" ]; then
  if [ "$blockers" -eq 1 ]; then
    say "② 缺 config.toml / run.sh —— 等 ① 就位后,在容器里跑:"
  else
    say "① 缺 config.toml / run.sh —— 在容器里跑:"
  fi
  say "     bash $CC_DIR/deploy-codex.sh"
  blockers=1
fi

say ""
if [ "$blockers" -eq 0 ]; then
  say "✅ 配置齐了。拉起服务:"
else
  say "▸ 补齐后拉起服务:"
fi
say "     bash $CC_DIR/restore-all.sh"
say ""
say "   restore-all.sh 幂等,已经在跑的服务会跳过,跑完自己打汇总表。"
