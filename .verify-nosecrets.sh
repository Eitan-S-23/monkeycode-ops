#!/bin/bash
# 密钥泄漏闸门:确认仓库里没有任何真实凭证
#
# 为什么要有它:
#   本仓库的前提是"零密钥也能重建" —— bots.env 与 providers.toml 都由本机重新
#   生成,不进仓库(见 README)。但 .gitignore 只挡得住**文件名**,挡不住有人把
#   密钥粘贴进脚本、或者把某个文件改个名字就提交上去。
#
#   而且这个仓库是要推到 GitHub 的,推上去就撤不回来了 —— 所以用"真实值比对"
#   而不是"模式匹配":从两个密钥文件里把真值抠出来,逐条去已跟踪文件里搜。
#   模式匹配会漏掉长得不像密钥的密钥,真值比对不会。
#
# 判据:变量名里带 KEY / SECRET / TOKEN / PASSWORD 的才算凭证。
#   CODEX_MODEL、CODEX_BASE、CLAUDE_BASE 这类是模型名和中转站地址,本来就该
#   出现在脚本的用法说明和测试夹具里,命中它们不算泄漏 —— 否则这个闸门会因为
#   天天误报而被无视,那才是真的危险。
#
# 用法: bash .verify-nosecrets.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

fail=0
SECRET_VAR_RE='(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)'

echo "══ 1. 密钥文件本身没有被跟踪 ══"
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "  ⚠️ 还没 git init,跳过(先 init 再跑这个闸门)"
else
  for f in bots.env providers.toml; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      echo "  ❌ $f 已被 git 跟踪 —— 它含真实凭证,必须从索引里移除"
      fail=1
    else
      echo "  ✅ $f 未被跟踪"
    fi
  done
fi

echo
echo "══ 2. 真实凭证值没有出现在任何已跟踪文件里 ══"
PYTHONIOENCODING=utf-8 python - "$SECRET_VAR_RE" <<'PYEOF'
import re, pathlib, subprocess, sys

var_re = re.compile(sys.argv[1])

# 值 -> 来源(变量名或 api_key)。只留凭证类,值本身不打印。
origin = {}
p = pathlib.Path('providers.toml')
if p.is_file():
    for m in re.finditer(r'api_key\s*=\s*"([^"]{12,})"', p.read_text(encoding='utf-8')):
        origin.setdefault(m.group(1), 'providers.toml:api_key')
b = pathlib.Path('bots.env')
if b.is_file():
    for line in b.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, v = line.split('=', 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if len(v) >= 12 and var_re.search(k):
            origin.setdefault(v, 'bots.env:' + k)

if not origin:
    print('  ⚠️ 本机找不到 providers.toml / bots.env,没得比对 —— 闸门这次是空转的')
    raise SystemExit(0)

print('  凭据值 %d 条参与比对(值不打印)' % len(origin))

tracked = subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout.split()
if not tracked:
    tracked = [str(q) for q in pathlib.Path('.').rglob('*')
               if q.is_file() and not any(part.startswith('.git') for part in q.parts)]

hits = 0
for f in tracked:
    try:
        text = pathlib.Path(f).read_text(encoding='utf-8', errors='replace')
    except OSError:
        continue
    for v, label in origin.items():
        if v in text:
            print('  ❌ %s 里出现 %s 的值(长度 %d)' % (f, label, len(v)))
            hits += 1

if hits:
    raise SystemExit(1)
print('  ✅ %d 个已跟踪文件里,没有任何凭据值' % len(tracked))
PYEOF
[ $? -ne 0 ] && fail=1

echo
echo "══ 3. 真实中转站地址没有出现在已跟踪文件里 ══"
# 这个仓库是**公开**的。地址本身不含密钥,但会暴露用的是哪几家中转 —— 属于不该
# 公开的基础设施信息。脚本里的示例一律用文档保留域名 relay.example。
#
# 测试夹具确实需要"一个看起来像地址的东西"时,用互不相同的 relay.example/vN
# 占位符即可 —— 被测逻辑只关心地址的**形状和唯一性**,不关心它是否真能连上。
# 别为了"更真实"把真地址写进夹具。
PYTHONIOENCODING=utf-8 python - <<'PYEOF'
import re, pathlib, subprocess

hosts = set()

def add(u):
    m = re.match(r'https?://([^/\s"]+)', u)
    # example 是 RFC 2606 保留给文档用的 TLD,localhost 同理 —— 都不算真实主机
    if m and 'example' not in m.group(1) and 'localhost' not in m.group(1):
        hosts.add(m.group(1))

b = pathlib.Path('bots.env')
if b.is_file():
    for line in b.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, v = line.split('=', 1)
        v = v.strip().strip('"').strip("'")
        if 'BASE' in k.strip() and v.startswith('http'):
            add(v)

p = pathlib.Path('providers.toml')
if p.is_file():
    for m in re.finditer(r'base_url\s*=\s*"([^"]+)"', p.read_text(encoding='utf-8')):
        add(m.group(1))

if not hosts:
    print('  ⚠️ 本机取不到真实地址,这一步是空转的')
    raise SystemExit(0)

print('  真实主机 %d 个参与比对(主机名不打印)' % len(hosts))
tracked = subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout.split()
bad = []
for f in tracked:
    try:
        text = pathlib.Path(f).read_text(encoding='utf-8', errors='replace')
    except OSError:
        continue
    for h in hosts:
        if h in text:
            bad.append(f)
            break

if bad:
    for f in bad:
        print('  ❌ %s 含真实中转站主机名' % f)
    raise SystemExit(1)
print('  ✅ %d 个已跟踪文件里没有真实主机名' % len(tracked))
PYEOF
[ $? -ne 0 ] && fail=1

echo
echo "════════════════════════════════════════"
if [ "$fail" -eq 0 ]; then
  echo "✅ 闸门通过:仓库里没有真实凭证,也没有真实地址"
else
  echo "❌ 闸门拦下:仓库里检测到凭据或真实地址,不要推送"
  exit 1
fi
