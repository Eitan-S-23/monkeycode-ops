#!/usr/bin/env python3
"""按 secret.txt + providers.toml 生成容器用的 bots.env。

为什么要有这一步:
    deploy-codex.sh 从 /workspace/cc-connect/bots.env 读凭证与 provider,
    但那份文件在容器里,而凭证明文只在本机 secret.txt 里。手工填一次容易,
    填错了却要等到"冒烟测试失败"才暴露 —— 故做成脚本,顺便把 provider
    取值也从 providers.toml 里取准,避免两处手抄不一致。

三个飞书 App 的分工(secret.txt 里的三段):
    bot            → 容器里的命令机器人,已有,本脚本**不用**
    monkey-codex   → cc-connect 的 codex project
    monkey-claude  → cc-connect 的 claude project
    一个 App 的长连接只能挂一个 project,所以 codex / claude 必须各占一个。

用法:
    python make-bots-env.py                      # 写到 ./bots.env
    python make-bots-env.py --out /tmp/bots.env
    python make-bots-env.py --check              # 只校验,不写文件
    python make-bots-env.py --smoke-provider lilililwan --smoke-model deepseek-v4-flash
        # 冒烟测试(codex 专用)改走另一条线验连通性;不指定就与 codex 主线路一致。

安全:输出只报键名与 base_url / model —— api_key 与 app_secret 一律不打印,
    写出的文件 chmod 600。
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

# 要哪两个 App,以及它们分别对应 bundle 里的哪个 @project
APPS = [("codex", "monkey-codex"), ("claude", "monkey-claude")]

# secret.txt 里的值是全角冒号(：),也容忍半角 —— 手抄混用过,
# 只认一种的话会以"这一段没解析出来"的形式失败,排查起来毫无线索。
BLOCK_RE = re.compile(
    r"^\s*(?P<label>[\w-]+)\s*$\s*^\s*App ID\s*[:：]\s*(?P<app_id>\S+)\s*$"
    r"\s*^\s*App Secret\s*[:：]\s*(?P<secret>\S+)\s*$",
    re.M,
)


def parse_secrets(path):
    """解析 secret.txt,返回 {段名: (app_id, app_secret)}"""
    text = path.read_text(encoding="utf-8")
    found = {}
    for m in BLOCK_RE.finditer(text):
        found[m.group("label")] = (m.group("app_id"), m.group("secret"))
    if not found:
        raise SystemExit(
            f"❌ {path} 里没解析出任何 App 段。\n"
            "   期望的格式是「段名 / App ID：xxx / App Secret：yyy」三行一组。"
        )
    return found


def parse_bundle_sections(path):
    """把 providers.toml 切成 {project: (默认 provider 名, 正文)}"""
    secs, cur = {}, None
    for ln in path.read_text(encoding="utf-8").splitlines():
        s = ln.strip()
        m = re.match(r"^#\s*@project\s+(\S+)\s*$", s)
        if m:
            cur = m.group(1)
            secs[cur] = {"default": "", "lines": []}
            continue
        m = re.match(r"^#\s*@default-provider\s+(\S+)\s*$", s)
        if m:
            if cur is None:
                raise SystemExit(f"❌ {path}: @default-provider 出现在任何 @project 之前")
            secs[cur]["default"] = m.group(1)
            continue
        if s.startswith("#"):
            continue
        if cur is None:
            if s:
                raise SystemExit(f"❌ {path}: 这行不属于任何 @project 段: {s[:60]!r}")
            continue
        secs[cur]["lines"].append(ln)
    return secs


def load_providers(path, secs, project):
    """取该段全部 provider(借 tomllib 解析,不手写 TOML 解析器)。

    正文是一段裸的 [[projects.agent.providers]],单拎出来不是合法 TOML ——
    给它套一个最小的 project 外壳再解析即可。
    """
    body = "\n".join(secs[project]["lines"]).strip("\n")
    if not body:
        raise SystemExit(f"❌ {path} 的 @project {project} 段是空的")
    import tomllib

    doc = tomllib.loads('[[projects]]\nname = "x"\n  [projects.agent]\n    type = "t"\n' + body)
    return doc["projects"][0]["agent"]["providers"]


def provider_by_name(path, provs, name, project):
    """按名字取 provider,取不到就把现有的名字列出来 —— 手抄 provider 名
    最容易错一个字母(例如 lilililwan 是三个 li),报错时必须给出候选。"""
    for p in provs:
        if p.get("name") == name:
            return p
    raise SystemExit(
        f"❌ {path}: {project} 段里没有名为 {name!r} 的 provider"
        f"(有: {', '.join(str(x.get('name')) for x in provs[:12])}…)"
    )


def pick_provider(path, secs, project):
    """取该段 @default-provider 指定的那个 provider"""
    want = secs[project]["default"]
    if not want:
        raise SystemExit(f"❌ {path} 的 @project {project} 段没有 @default-provider")
    return provider_by_name(path, load_providers(path, secs, project), want, project)


def main():
    ap = argparse.ArgumentParser(description="生成容器用的 bots.env")
    ap.add_argument("--secrets", default=str(ROOT / "secret.txt"), help="凭证明细文件")
    ap.add_argument("--bundle", default=str(HERE / "providers.toml"), help="导出好的 provider 包")
    ap.add_argument("--out", default=str(HERE / "bots.env"), help="输出路径(默认 <本目录>/bots.env)")
    ap.add_argument("--check", action="store_true", help="只校验,不写文件")
    ap.add_argument("--smoke-provider", default="",
                    help="冒烟测试改用 codex 段里的哪个 provider(默认与 codex 主线路相同)")
    ap.add_argument("--smoke-model", default="",
                    help="冒烟测试用哪个模型名(默认取该 provider 的 model);"
                         "中转站有、providers.toml 里没配别名的模型也可直接写")
    args = ap.parse_args()

    secrets = parse_secrets(pathlib.Path(args.secrets))
    secs = parse_bundle_sections(pathlib.Path(args.bundle))
    bundle = pathlib.Path(args.bundle)

    # 缺哪个 App 就直接点名,不要等到部署时才发现
    for kind, label in APPS:
        if label not in secrets:
            raise SystemExit(
                f"❌ {args.secrets} 里没有 {label!r} 这段;"
                f"现有: {', '.join(secrets) or '(空)'}"
            )
        if kind not in secs:
            raise SystemExit(f"❌ {args.bundle} 里没有 @project {kind} 段")

    # 主线路:各段 @default-provider
    mains = {kind: pick_provider(bundle, secs, kind) for kind, _ in APPS}

    # 冒烟线路:只在 codex 段里找 —— 冒烟测试本身就是 codex 的(用 codex CLI + wire_api=chat),
    # 拿 claude 段的 base_url 去跑必然会因为多了/少了 /v1 而失败。模型名可单独给:
    # 验的是"这个中转站通不通、这个模型名存不存在",不需要 providers.toml 先配好它。
    smoke_prov = mains["codex"]
    if args.smoke_provider:
        smoke_prov = provider_by_name(bundle, load_providers(bundle, secs, "codex"),
                                      args.smoke_provider, "codex")
    smoke_model = args.smoke_model or smoke_prov["model"]

    lines = [
        "# 由 cc-connect-ops/make-bots-env.py 生成 —— 含真实密钥,当密钥文件对待",
        "# deploy-codex.sh 会读这份文件;改完记得把权限收回 600。",
        "",
        "# ── 飞书机器人凭证(三个 App 各管一摊,不能混用) ──",
        "#   bot 那个是命令机器人,cc-connect 不用它。",
    ]
    for kind, label in APPS:
        app_id, secret = secrets[label]
        var = kind.upper()
        lines.append(f"# {label}")
        lines.append(f"{var}_FEISHU_APP_ID={app_id}")
        lines.append(f"{var}_FEISHU_APP_SECRET={secret}")

    lines += ["", "# ── provider:取 providers.toml 里各段的默认 provider ──"]
    for kind, _ in APPS:
        prov = mains[kind]
        var = kind.upper()
        lines.append(f"# {kind}: {prov.get('name')}")
        lines.append(f"{var}_BASE={prov['base_url']}")
        lines.append(f"{var}_MODEL={prov['model']}")
        lines.append(f"{var}_KEY={prov['api_key']}")

    # 冒烟测试走哪条线。与主线路相同时显式写出来(而不是留空依赖回退),
    # 让"验的和用的是不是一条线"在文件里一眼可查 —— 这两条线分开之后最容易出的
    # 错就是:冒烟过了,主线路其实通不了,问题拖到机器人不回话才暴露。
    lines += [
        "",
        "# ── 冒烟测试线路:只影响 deploy-codex.sh 第 2 步的连通性验证,不写进生成的配置 ──",
        f"# 取自 codex 段 provider {smoke_prov.get('name')}"
        + (f";模型名由 --smoke-model 指定" if args.smoke_model else ""),
    ]
    if smoke_prov is mains["codex"]:
        lines.append("# 与 codex 主线路相同 —— 若改上面的 CODEX_BASE/MODEL/KEY,这里要一起改")
    else:
        lines.append(f"# 与 codex 主线路({mains['codex'].get('name')})不同:冒烟通过 ≠ 主线路可用")
    lines += [
        f"CODEX_SMOKE_BASE={smoke_prov['base_url']}",
        f"CODEX_SMOKE_MODEL={smoke_model}",
        f"CODEX_SMOKE_KEY={smoke_prov['api_key']}",
    ]

    text = "\n".join(lines) + "\n"

    if args.check:
        print("  ✅ 校验通过(未写文件)")
    else:
        out = pathlib.Path(args.out)
        # newline="" 关掉 Windows 的 \n→\r\n 转换:deploy-codex.sh 虽然会剥掉行尾的 CR,
        # 但没必要把 CR 带进去 —— 少一层依赖少一处出错。
        with open(out, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        try:
            out.chmod(0o600)
        except OSError:
            pass  # Windows 上 chmod 只映射只读标志,真正生效在容器里
        print(f"  ✅ 已写出 {out}({len(text.encode('utf-8'))} 字节,权限 600)")

    # 只报键名与可公开字段 —— 密钥、App Secret 一律不打印
    for kind, label in APPS:
        prov = mains[kind]
        print(f"     {kind:7s} App={label:14s} provider={prov.get('name'):18s} "
              f"model={prov['model']}")
        print(f"             base_url={prov['base_url']}")
    print(f"     smoke   App=-              provider={smoke_prov.get('name'):18s} "
          f"model={smoke_model}")
    print(f"             base_url={smoke_prov['base_url']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
