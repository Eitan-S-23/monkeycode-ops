#!/usr/bin/env python3
"""按 secret.txt 生成容器用的 bots9.env(9 个 codex 机器人的飞书 App 凭证)。

为什么单独一个生成器:
    add-codex-bots.py 读的是"键名即契约"的 env 文件(CODEX<N>_APP_ID /
    CODEX<N>_APP_SECRET),而凭证明文只在本机 secret.txt 里。手工抄 9 组容易错一位,
    错了要等到"某个机器人连不上"才暴露 —— 故做成脚本,顺便把"哪个段对应哪个 project"
    这条映射固化下来。同时,凭证明文不进仓库(见 README「密钥从哪来」)。

为什么键名用序号而不是段落顺序:
    顺序会被人手重排(在 secret.txt 里挪一段、插一段),重排之后静默换掉一台机器人是
    最难查的一类故障;序号是写在键名里的,谁也动不了。

用法:
    python make-bots9-env.py                     # 读 ../secret.txt,写到 ./bots9.env
    python make-bots9-env.py --secret /path/secret.txt
    python make-bots9-env.py --out /tmp/bots9.env
    python make-bots9-env.py --check             # 只校验,不写文件

安全:输出只报段名、project 名与 App ID,App Secret 一律不打印;写出的文件 chmod 600。
"""

import argparse
import pathlib
import re
import sys

# Windows 上 python 默认按 GBK 编码 stdout,打印 ✅ 会抛 UnicodeEncodeError
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):  # 3.7 以下没有 reconfigure
        pass

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

# secret.txt 里的值是全角冒号(：),也容忍半角 —— 手抄混用过,只认一种的话会以
# "这一段没解析出来"的形式失败,排查起来毫无线索。与 make-bots-env.py 同一套规则。
BLOCK_RE = re.compile(
    r"^\s*(?P<label>[\w-]+)\s*$\s*^\s*App ID\s*[:：]\s*(?P<app_id>\S+)\s*$"
    r"\s*^\s*App Secret\s*[:：]\s*(?P<secret>\S+)\s*$",
    re.M,
)

# 段名 → project 名。只认 monkey-codex<序号>:这一份是给"9 个 codex 机器人"用的,
# 段名对不上就说明 secret.txt 里混进了别的东西(命令机器人、claude 机器人),
# 静默忽略等于"以为部署了 9 个,其实少了几个"。
LABEL_RE = re.compile(r"^monkey-codex(?P<num>\d+)$")


def parse_secrets(path):
    """解析 secret.txt,返回 [(段名, 序号, app_id, app_secret)],按序号排序"""
    text = path.read_text(encoding="utf-8")
    found, seen = [], set()
    for m in BLOCK_RE.finditer(text):
        label = m.group("label")
        if label in seen:
            raise SystemExit(f"❌ {path}: 段名 {label!r} 出现了两次")
        seen.add(label)
        lm = LABEL_RE.match(label)
        if not lm:
            raise SystemExit(
                f"❌ {path}: 段名 {label!r} 不是 monkey-codex<序号> 的形状。\n"
                "   本生成器只处理 codex 机器人那几段;命令机器人 / claude 机器人的凭证\n"
                "   属于 deploy-codex.sh 的 bots.env,不要混进这个文件。"
            )
        found.append((label, int(lm.group("num")), m.group("app_id"), m.group("secret")))
    if not found:
        raise SystemExit(
            f"❌ {path} 里没解析出任何 App 段。\n"
            "   期望的格式是「段名 / App ID：xxx / App Secret：yyy」三行一组。"
        )

    nums = [n for _, n, _, _ in found]
    dup = sorted({n for n in nums if nums.count(n) > 1})
    if dup:
        raise SystemExit(f"❌ {path}: 序号重复 —— {', '.join('monkey-codex' + str(n) for n in dup)}")
    found.sort(key=lambda item: item[1])
    return found


def render(entries, source):
    """生成 bots9.env 的全文"""
    lines = [
        "# 由 cc-connect-ops/make-bots9-env.py 生成 —— 含真实密钥,当密钥文件对待",
        f"# 来源: {source}",
        "# add-codex-bots.py 读这份文件;键名里的序号决定 project 名(codex1 / codex2 …)。",
        "# 改完记得把权限收回 600;这个文件不进仓库(.gitignore 已挡)。",
        "",
    ]
    for label, num, app_id, secret in entries:
        lines.append(f"# {label} → project codex{num}")
        lines.append(f"CODEX{num}_APP_ID={app_id}")
        lines.append(f"CODEX{num}_APP_SECRET={secret}")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description="按 secret.txt 生成容器用的 bots9.env",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--secret", default=str(ROOT / "secret.txt"),
                    help=f"凭证来源(默认 {ROOT / 'secret.txt'})")
    ap.add_argument("--out", default=str(HERE / "bots9.env"),
                    help=f"输出文件(默认 {HERE / 'bots9.env'})")
    ap.add_argument("--check", action="store_true", help="只校验,不写文件")
    args = ap.parse_args()

    src = pathlib.Path(args.secret)
    if not src.is_file():
        raise SystemExit(f"❌ 找不到凭证来源: {src}")

    entries = parse_secrets(src)
    print(f"凭证来源: {src}")
    print(f"解析出 {len(entries)} 个 App(按序号排序,App Secret 不打印):")
    for label, num, app_id, _ in entries:
        print(f"  · {label:<18} → project codex{num:<2} App {app_id[:14]}…")

    # 段名里的序号必须是连续的:缺号意味着 secret.txt 少了一段,而"少部署一台机器人"
    # 不会自己暴露 —— 除非这里说出来。
    nums = [n for _, n, _, _ in entries]
    gaps = [n for n in range(min(nums), max(nums) + 1) if n not in nums]
    if gaps:
        print(f"\n  ⚠️ 序号不连续,缺: {', '.join(str(n) for n in gaps)}"
              "(如果本来就只部署这些,忽略即可)")

    out = pathlib.Path(args.out)
    text = render(entries, src)
    if args.check:
        # 回读校验:生成物必须能被子脚本按同一套规则解析出来
        keys = re.findall(r"^(CODEX\d+_(?:APP_ID|APP_SECRET))=", text, re.M)
        print(f"\n--check:{len(keys)} 个键,未写文件")
        return 0

    out.write_text(text, encoding="utf-8")
    try:
        out.chmod(0o600)
    except OSError:
        pass
    print(f"\n✅ 已写入 {out}({out.stat().st_size} 字节,权限 600)")
    print("   投递进容器:bash make-upload-cmd.sh " + out.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
