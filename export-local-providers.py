#!/usr/bin/env python3
"""把本机 cc-connect 配置里的 provider 列表导出成一个可直接合并的片段文件。

用途(在你自己电脑上跑,不在容器里跑):
    容器里那份 config.toml 每个 project 只有一个 provider,而本机配了二三十个
    中转站、几百条模型别名。本脚本把本机 codex / claude 两个 project 的 provider
    列表一起抠出来写进同一个文件,再由容器端的 apply-providers.py 一次性并进去。

    两个 project 的 provider 是两份不同的数据(条数、密钥、中转站、别名、env 都
    不同),所以文件里用 "# @project <名字>" 分段 —— 不是一份通用配置到处套。

密钥处理:
    导出的文件里含真实 api_key(不这样搬不过去)。所以:
      · 本脚本只往你本机磁盘写,不打印任何密钥值;
      · 生成的文件请当密钥文件对待,别提交进仓库、别贴进聊天;
      · 它和 config.toml 同级敏感,生成时已 chmod 600。
    这不是新增的风险面 —— 目标文件 config.toml 本来就含同样的密钥,
    只是从一份密钥文件变成两份。

用法:
    python export-local-providers.py                  # 默认取 codex-test2 / claude-test2
    python export-local-providers.py --codex <项目名> --claude <项目名>
    python export-local-providers.py --out-dir ./out

输出:
    <out-dir>/providers.toml   两个 project 的 provider 段,按 @project 标记分段
"""

import argparse
import json
import os
import pathlib
import sys
import tomllib

# 输出流定死 UTF-8:Windows 上 python 默认按 GBK 编码 stdout,打印 ✅ 会抛
# UnicodeEncodeError —— 而那通常发生在文件"已经写好之后",会让人误判成失败。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):   # 3.7 以下没有 reconfigure
        pass

DEFAULT_CONFIG = pathlib.Path.home() / ".cc-connect" / "config.toml"

# agent.options 里这些键与"跑在哪台机器上"强绑定,搬过去只会出错,一律不带。
# work_dir / codex_home 是路径;http_proxy / https_proxy 指向本机端口。
# 容器里的 work_dir 等由部署脚本写死成 /workspace,不需要也不该被覆盖。
DROP_OPTIONS = {"work_dir", "codex_home", "http_proxy", "https_proxy", "no_proxy"}


def q(value):
    """TOML 基本字符串。json.dumps 的转义规则与 TOML 基本字符串兼容,且能正确处理
    引号、反斜杠、换行 —— model 名里带 [1M] 这种也不需要特殊照顾。"""
    return json.dumps("" if value is None else str(value), ensure_ascii=False)


def provider_usable(prov):
    """返回 (可用?, 原因)。不可用的直接剔除,不能带进容器:
    带上去只会在 cc-connect 启动或 /model 时报错,而在容器里排查比在本机麻烦得多。"""
    base = str(prov.get("base_url") or "").strip()
    if not base.startswith("http"):
        return False, f"base_url 不是 http 地址: {base!r}"
    if not str(prov.get("api_key") or "").strip():
        return False, "api_key 为空"
    if not str(prov.get("name") or "").strip():
        return False, "provider 没有 name"
    return True, ""


def render_providers(provs, indent):
    """把 provider 列表渲染成 TOML 子表文本。

    顺序刻意与 deploy-codex.sh 生成器一致:先 models 再 env。反过来写会让
    env 之后出现的 [[…models]] 归属变得难以预料,而这里的表头是绝对路径,
    一旦解析错就会静默丢模型 —— 宁可照着已验证过的顺序来。
    """
    pad = " " * indent
    chunks = []
    for prov in provs:
        lines = [
            f"{pad}[[projects.agent.providers]]",
            f'{pad}  name = {q(prov.get("name"))}',
            f'{pad}  api_key = {q(prov.get("api_key"))}',
            f'{pad}  base_url = {q(prov.get("base_url"))}',
        ]
        if prov.get("model"):
            lines.append(f'{pad}  model = {q(prov.get("model"))}')
        for m in prov.get("models") or []:
            lines.append(f"{pad}  [[projects.agent.providers.models]]")
            lines.append(f'{pad}    model = {q(m.get("model"))}')
            if m.get("alias"):
                lines.append(f'{pad}    alias = {q(m.get("alias"))}')
        env = prov.get("env") or {}
        if env:
            lines.append(f"{pad}  [projects.agent.providers.env]")
            for k, v in env.items():
                lines.append(f"{pad}    {k} = {q(v)}")
        chunks.append("\n".join(lines))
    return "\n\n".join(chunks)


def collect(doc, project_name, kind):
    """从本机配置里取出一个 project 的 provider 段,返回一个待渲染的分段"""
    proj = next((p for p in doc.get("projects", []) if p.get("name") == project_name), None)
    if proj is None:
        names = ", ".join(p.get("name", "?") for p in doc.get("projects", []))
        raise SystemExit(f"❌ 找不到 project {project_name!r};可选: {names}")

    agent = proj.get("agent") or {}
    opts = agent.get("options") or {}
    dropped = sorted(set(opts) & DROP_OPTIONS)
    default_provider = str(opts.get("provider") or "")

    kept, skipped = [], []
    for prov in agent.get("providers") or []:
        ok, why = provider_usable(prov)
        (kept if ok else skipped).append((prov, why))
    if not kept:
        raise SystemExit(f"❌ {project_name} 里没有可用的 provider,不能导出")

    kept_names = [p.get("name") for p, _ in kept]
    if default_provider and default_provider not in kept_names:
        # 默认 provider 指向一个被剔除的项,搬过去会让 cc-connect 以
        # "找不到 provider"启动失败。这是本机配置自身的问题,不能带到容器里。
        raise SystemExit(
            f"❌ {project_name} 的默认 provider {default_provider!r} 不在可用列表里,"
            f"先在本机配置里修好"
        )

    body = render_providers([p for p, _ in kept], 2)
    n_models = sum(len(p.get("models") or []) for p, _ in kept)

    print(f"  ✅ {kind} ← 本机 {project_name}")
    print(f"     provider {len(kept)} 个,模型别名 {n_models} 条")
    if default_provider:
        print(f"     默认 provider: {default_provider}")
    else:
        print("     ⚠️ 本机没设默认 provider,合并后保持容器现有的")
    if dropped:
        print(f"     ➖ 未搬运(与本机绑定,容器里不适用): {', '.join(dropped)}")
    for prov, why in skipped:
        print(f"     ✗ 剔除 {prov.get('name')!r}: {why}")

    return {"kind": kind, "source": project_name, "default": default_provider, "body": body}


def render_bundle(sections):
    """把各分段渲染成一个文件。@project 标记是容器端唯一的归类依据 ——
    它写在内容里,不依赖文件名,所以文件被改名/重传都不会归错 project。"""
    parts = [
        "# 由 export-local-providers.py 从本机 cc-connect 配置导出",
        "# 含真实 api_key —— 当密钥文件对待,别提交进仓库、别贴进聊天",
        "# 每个 @project 段整体替换容器里同名 project 的 provider 列表",
    ]
    for sec in sections:
        parts.append(f"#   {sec['kind']} ← 本机 project {sec['source']}")
    for sec in sections:
        parts.append("")
        parts.append(f"# @project {sec['kind']}")
        if sec["default"]:
            parts.append(f"# @default-provider {sec['default']}")
        parts.append(sec["body"])
    return "\n".join(parts) + "\n"


def main():
    ap = argparse.ArgumentParser(
        description="导出本机 cc-connect 的 provider 列表为单个可合并的片段文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--config", default=str(DEFAULT_CONFIG), help=f"本机配置文件(默认 {DEFAULT_CONFIG})")
    ap.add_argument("--codex", default="codex-test2", help="作为 codex 模板的本机 project 名")
    ap.add_argument("--claude", default="claude-test2", help="作为 claude 模板的本机 project 名")
    ap.add_argument("--out-dir", default=".", help="输出目录(默认当前目录)")
    args = ap.parse_args()

    cfg = pathlib.Path(args.config).expanduser()
    if not cfg.is_file():
        raise SystemExit(f"❌ 找不到本机配置: {cfg}")
    doc = tomllib.loads(cfg.read_text(encoding="utf-8"))
    out_dir = pathlib.Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"本机配置: {cfg}")
    print()
    sections = [collect(doc, args.codex, "codex")]
    print()
    sections.append(collect(doc, args.claude, "claude"))

    out_path = out_dir / "providers.toml"
    out_path.write_text(render_bundle(sections), encoding="utf-8")
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass    # Windows 上 chmod 只映射只读标志,失败不影响正确性

    print()
    print(f"  ✅ 已写入 {out_path} ({out_path.stat().st_size} 字节)")
    print()
    print("下一步:把 providers.toml 传进容器,再执行")
    print("  python3 apply-providers.py providers.toml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
