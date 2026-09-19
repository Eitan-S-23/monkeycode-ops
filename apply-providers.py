#!/usr/bin/env python3
"""把本机导出的 provider 段合并进容器的 config.toml。

配套 export-local-providers.py 使用:那个在本机跑、生成一个 providers.toml,
这个在容器里跑、把其中的各段并进 /workspace/cc-connect/config.toml。

为什么是"替换整个 provider 段"而不是追加:
    追加会留下旧的 main provider。它的 base_url/模型来自 bots.env,与本机那套
    无关,留在 /model 列表里只会让人选错。所以整段替换,顺带把
    agent.options.provider 改成片段声明的默认值。

用法(容器内):
    python3 apply-providers.py providers.toml
    python3 apply-providers.py providers.toml --only codex
    python3 apply-providers.py providers.toml --dry-run

改完必须重启才生效,命令脚本会提示。
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

# 输出流定死 UTF-8:容器 LANG 未必是 UTF-8,且本机(Windows)默认 GBK。
# 不定死的话,打印 ✅ 会在"配置已经写好之后"抛 UnicodeEncodeError,
# 脚本以非零码退出 —— 和真的失败分不开。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):   # 3.7 以下没有 reconfigure
        pass

DEFAULT_CONFIG = "/workspace/cc-connect/config.toml"
PROC_MATCH = "^/workspace/cc-connect/cc-connect"

# export-local-providers.py 写进文件的分段标记。两者必须逐字一致。
PROJECT_RE = re.compile(r"^#\s*@project\s+(\S+)\s*$")
DEFAULT_RE = re.compile(r"^#\s*@default-provider\s+(\S+)\s*$")


def toml_load(text):
    """标准库 tomllib(3.11+);更老的 python 返回 None,由调用方降级为结构性自检"""
    try:
        import tomllib
    except ModuleNotFoundError:
        return None
    try:
        return tomllib.loads(text)
    except Exception as error:  # noqa: BLE001 —— 解析失败原因多样,统一报给用户
        raise SystemExit(f"❌ config.toml 不是合法 TOML,先修好再跑本脚本:\n   {error}")


def parse_bundle(text, path):
    """把导出文件切成 [(project 名, 默认 provider, 片段正文)]。

    只认文件里的 @project 标记,不按文件名猜、不按内容嗅探 —— 猜错的代价是把
    claude 的 provider 塞进 codex,而两者的 env 语义完全不同(一个是
    ANTHROPIC_DEFAULT_*,一个是 codex 的),错了不会报错,只会静默跑歪。
    """
    sections = []
    cur = None
    for ln in text.splitlines():
        s = ln.strip()
        m = PROJECT_RE.match(s)
        if m:
            if cur:
                sections.append(cur)
            cur = {"project": m.group(1), "default": "", "lines": []}
            continue
        m = DEFAULT_RE.match(s)
        if m:
            if cur is None:
                raise SystemExit(f"❌ {path}: @default-provider 出现在任何 @project 之前")
            if cur["default"]:
                raise SystemExit(f"❌ {path}: {cur['project']} 段里出现了两行 @default-provider")
            cur["default"] = m.group(1)
            continue
        if s.startswith("#"):
            continue
        if cur is None:
            if not s:
                continue
            raise SystemExit(f"❌ {path}: 这行不属于任何 @project 段: {s[:60]!r}")
        cur["lines"].append(ln)
    if cur:
        sections.append(cur)

    out, seen = [], set()
    for sec in sections:
        if sec["project"] in seen:
            raise SystemExit(f"❌ {path}: project {sec['project']} 出现了两次")
        seen.add(sec["project"])
        body = "\n".join(sec["lines"]).strip("\n")
        if not body:
            raise SystemExit(f"❌ {path}: project {sec['project']} 段里没有任何 provider")
        out.append((sec["project"], sec["default"], body))
    if not out:
        raise SystemExit(f"❌ {path}: 没解析出任何 @project 段,文件是不是被改坏了?")
    return out


def check_fragment(body, kind, path):
    """片段自身先解析一遍。片段里的表头是绝对路径,独立解析要套一层 [[projects]]。"""
    doc = toml_load('[[projects]]\nname = "x"\n  [projects.agent]\n    type = "t"\n' + body)
    if doc is None:
        return []       # 无 tomllib,交给整份配置的最终回验兜底
    provs = doc["projects"][0]["agent"].get("providers") or []
    if not provs:
        raise SystemExit(f"❌ {path} 的 {kind} 段里没有解析出任何 provider")
    names = [p.get("name") for p in provs]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        # 同名 provider 在 cc-connect 里是后一个覆盖前一个,/model 会少东西
        raise SystemExit(f"❌ {path} 的 {kind} 段里 provider 名重复: {', '.join(sorted(dup))}")
    blank = [p.get("name") for p in provs if not str(p.get("base_url") or "").startswith("http")]
    if blank:
        raise SystemExit(f"❌ {path} 的 {kind} 段里这些 provider 的 base_url 不是 http 地址: {', '.join(map(str, blank))}")
    return provs


def project_blocks(lines):
    """切出每个 [[projects]] 的文本区块(与 set-heartbeat.py 同一套规则)"""
    starts = [i for i, ln in enumerate(lines) if ln.strip() == "[[projects]]"]
    blocks = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        name = ""
        for ln in lines[start + 1:end]:
            s = ln.strip()
            if s.startswith("["):       # 越过子表头就不再找,避免误取 providers.name
                break
            m = re.match(r'name\s*=\s*"([^"]*)"', s)
            if m:
                name = m.group(1)
                break
        blocks.append({"name": name, "start": start, "end": end})
    return blocks


def find_provider_span(lines, block):
    """返回 provider 段的行区间 [起, 止);找不到返回 None。

    段落从第一个 [[projects.agent.providers]] 开始,到下一个不属于 providers
    的 projects 子表为止 —— 这样连 models / env 两个子子表一起吃掉。
    用"下一个 projects.* 表头"而不是"缩进变浅"来判边界:缩进是人写的,
    改一次排版就会判错,而表头路径是 TOML 语义,怎么写都不会变。
    """
    start = None
    for i in range(block["start"], block["end"]):
        if lines[i].strip() == "[[projects.agent.providers]]":
            start = i
            break
    if start is None:
        return None
    end = block["end"]
    for i in range(start + 1, block["end"]):
        s = lines[i].strip()
        if s.startswith("[") and "projects." in s and "agent.providers" not in s:
            end = i
            break
    # 回退掉段尾空行,避免替换后留下一串空行
    while end > start and not lines[end - 1].strip():
        end -= 1
    return start, end


def set_default_provider(lines, block, name):
    """把该 project 的 agent.options.provider 指向新默认值"""
    for i in range(block["start"], block["end"]):
        if lines[i].strip() == "[projects.agent.options]":
            for j in range(i + 1, block["end"]):
                s = lines[j].strip()
                if s.startswith("["):       # 出了 options 表
                    return False
                if re.match(r"provider\s*=", s):
                    pad = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                    lines[j] = f'{pad}provider = {json.dumps(name, ensure_ascii=False)}'
                    return True
    return False


def align(frag_lines, pad):
    """把片段缩进对齐到目标段落。

    必须"先减掉片段自身的最小缩进,再加 pad"。直接 pad+ln 会把片段原有缩进
    也叠上去 —— 第一次跑出 6 空格,第二次读到 6 就变 8,每跑一次多一层。
    内容没变、TOML 也照样解析得过,所以不会报错,只会让文件被反复改写
    (diff 永远不干净、备份失去意义)。
    """
    indents = [len(ln) - len(ln.lstrip()) for ln in frag_lines if ln.strip()]
    base = min(indents) if indents else 0
    return [(pad + ln[base:]) if ln.strip() else ln for ln in frag_lines]


def cc_running():
    """cc-connect 是否在跑。只用它决定提示语,判错不影响配置正确性 ——
    所以 pgrep 不存在时按"未运行"返回,绝不让脚本崩在收尾处。"""
    try:
        return subprocess.run(["pgrep", "-f", PROC_MATCH],
                              capture_output=True, text=True).returncode == 0
    except (FileNotFoundError, OSError):
        return False


def main():
    ap = argparse.ArgumentParser(
        description="把本机导出的 provider 段合并进容器 config.toml",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("bundle", help="export-local-providers.py 生成的 providers.toml")
    ap.add_argument("--config", default=DEFAULT_CONFIG, help=f"配置文件(默认 {DEFAULT_CONFIG})")
    ap.add_argument("--only", help="只合并其中一个 project(按 @project 名)")
    ap.add_argument("--dry-run", action="store_true", help="只报告将要做什么,不落盘")
    ap.add_argument("--restart", action="store_true", help="写完后重启 cc-connect")
    args = ap.parse_args()

    bundle_path = pathlib.Path(args.bundle)
    if not bundle_path.is_file():
        raise SystemExit(f"❌ 找不到片段文件: {bundle_path}")
    sections = parse_bundle(bundle_path.read_text(encoding="utf-8"), args.bundle)

    cfg = pathlib.Path(args.config)
    if not cfg.is_file():
        raise SystemExit(f"❌ 找不到配置文件: {cfg}")
    text = cfg.read_text(encoding="utf-8")
    toml_load(text)
    lines = text.splitlines()
    blocks = {b["name"]: b for b in project_blocks(lines)}

    print(f"配置文件: {cfg}")
    print(f"片段文件: {bundle_path}")
    print()

    plans = []
    for kind, default_provider, body in sections:
        if args.only and kind != args.only:
            continue
        block = blocks.get(kind)
        if block is None:
            print(f"  ✗ 跳过 {kind}: 配置里没有这个 project")
            continue
        provs = check_fragment(body, kind, args.bundle)
        span = find_provider_span(lines, block)
        n_models = sum(len(p.get("models") or []) for p in provs)
        print(f"  ▸ {kind}: provider {len(provs) or '(未解析)'} 个,模型别名 {n_models or '?'} 条")
        if default_provider:
            if not provs or any(p.get("name") == default_provider for p in provs):
                print(f"      默认 provider → {default_provider}")
            else:
                raise SystemExit(f"❌ {kind} 段声明的默认 provider {default_provider!r} 不在它的列表里")
        else:
            print("      ⚠️ 该段没有 @default-provider 标记,保持现有默认 provider")
        if span is None:
            print("      ⚠️ 该 project 原本没有 provider 段,将追加到区块末尾")
        plans.append((kind, block, span, body, default_provider))

    if not plans:
        if args.only:
            avail = ", ".join(k for k, _, _ in sections)
            raise SystemExit(f"❌ --only {args.only} 没匹配上;片段里有: {avail}")
        raise SystemExit("❌ 没有任何可执行的合并")

    if args.dry_run:
        print("\n--dry-run:未写盘")
        return 0

    # 从后往前改:前面的替换会改变行号,倒序改就不必重算区间
    plans.sort(key=lambda p: p[1]["start"], reverse=True)
    new_lines = list(lines)
    for kind, block, span, body, default_provider in plans:
        frag_lines = body.split("\n")
        if span is None:
            insert_at = block["end"]
            while insert_at > block["start"] and not new_lines[insert_at - 1].strip():
                insert_at -= 1
            new_lines[insert_at:insert_at] = [""] + frag_lines
        else:
            start, end = span
            # 片段缩进按 2 空格给的,这里对齐到原段首行,免得整段缩进不一致
            pad = new_lines[start][:len(new_lines[start]) - len(new_lines[start].lstrip())]
            new_lines[start:end] = align(frag_lines, pad)
        if default_provider:
            set_default_provider(new_lines, block, default_provider)

    new_text = "\n".join(new_lines) + "\n"

    # 落盘前回验:解析得过,且 provider 真的挂在对应 project 上
    doc2 = toml_load(new_text)
    if doc2 is None:
        print("  ⚠️ 当前 python 无 tomllib(需 3.11+),跳过 TOML 回验")
    else:
        by_name = {p.get("name"): p for p in doc2.get("projects", [])}
        for kind, _, _, _, default_provider in plans:
            provs = ((by_name.get(kind) or {}).get("agent") or {}).get("providers") or []
            if not provs:
                raise SystemExit(f"❌ 回验失败:{kind} 下没有解析出 provider")
            got_names = [p.get("name") for p in provs]
            if default_provider and default_provider not in got_names:
                raise SystemExit(f"❌ 回验失败:{kind} 的默认 provider {default_provider!r} 不在列表里")
            opt = ((by_name[kind].get("agent") or {}).get("options") or {}).get("provider")
            if default_provider and opt != default_provider:
                raise SystemExit(f"❌ 回验失败:{kind}.agent.options.provider 期望 {default_provider!r},实得 {opt!r}")
        print("\n  ✅ TOML 解析通过,provider 与默认项逐个核对无误")

    # 先备份:密钥文件改坏了能立刻还原,不用重新部署
    backup = cfg.with_suffix(cfg.suffix + ".pre-providers")
    backup.write_text(text, encoding="utf-8")
    cfg.write_text(new_text, encoding="utf-8")
    try:
        cfg.chmod(0o600)    # 含密钥,保持创建时的收紧权限
    except OSError:
        pass

    print(f"  ✅ 已写入 {cfg}")
    print(f"     备份: {backup}")
    print()
    if cc_running():
        if args.restart:
            try:
                subprocess.run(["pkill", "-f", PROC_MATCH], check=False)
                print("  🔄 已重启 cc-connect(watchdog 会在 10 秒内自动拉起)")
            except (FileNotFoundError, OSError):
                print(f"  ⚠️ 找不到 pkill,请手工重启: pkill -f {PROC_MATCH!r}")
                args.restart = False
        if not args.restart:
            print(f"  ⚠️ 配置改动需重启 cc-connect 才生效: pkill -f {PROC_MATCH!r}")
            print("     (会打断正在进行的对话,故没默认做;watchdog 10 秒内自动拉起)")
    else:
        print("  ℹ️ cc-connect 当前未在运行,下次启动时生效")
    print()
    print("  生效后在飞书里用 /model 查看模型列表。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
