#!/usr/bin/env python3
"""本地验证:抽出 deploy-codex.sh 的配置生成段,断言 provider 名两处一致。

复用既有的"替换输出路径 + tomllib 解析断言"做法,不重跑整脚本。
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import tomllib

HERE = pathlib.Path(__file__).resolve().parent
SH = HERE / "deploy-codex.sh"

src = SH.read_text(encoding="utf-8")
# 取 python3 - <<'PYEOF' 与行首 PYEOF 之间的正文
body = src.split("python3 - <<'PYEOF' || exit 1\n", 1)[1].split("\nPYEOF\n", 1)[0]
if "cx_pname" not in body or "cl_pname" not in body:
    sys.exit("❌ 配置生成段未引用 cx_pname/cl_pname")

failures = []


def run_case(label, cx_name, cl_name):
    """跑一种 provider 名场景,断言 options.provider 与 providers[0].name 一致"""
    local = []
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pname-"))
    out = tmp / "config.toml"
    code = body.replace(
        'pathlib.Path("/workspace/cc-connect/config.toml")', f'pathlib.Path(r"{out}")'
    )
    script = tmp / "gen.py"
    script.write_text(code, encoding="utf-8")

    env = dict(os.environ)
    env.update({
        "MODE": "new",
        "WANT_CLAUDE": "1",
        "CODEX_FEISHU_APP_ID": "cli_codex_placeholder",
        "CODEX_FEISHU_APP_SECRET": "secret_placeholder",
        "CODEX_KEY": "sk-placeholder", "CODEX_BASE": "https://up.example/v1",
        "CODEX_MODEL": "gpt-x", "CODEX_PROVIDER_NAME": cx_name,
        "CLAUDE_FEISHU_APP_ID": "cli_claude_placeholder",
        "CLAUDE_FEISHU_APP_SECRET": "secret_placeholder",
        "CLAUDE_KEY": "sk-placeholder", "CLAUDE_BASE": "https://up.example",
        "CLAUDE_MODEL": "claude-x", "CLAUDE_PROVIDER_NAME": cl_name,
    })
    proc = subprocess.run([sys.executable, str(script)], env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        failures.append(f"{label}: 生成失败 {proc.stderr.strip()}")
        print(f"  ❌ {label}: 生成失败")
        return

    cfg = tomllib.loads(out.read_text(encoding="utf-8"))
    # 期望值:脚本对空/纯空白回落 main,此处按同一规则推导
    expect = {
        "codex": (cx_name or "").strip() or "main",
        "claude": (cl_name or "").strip() or "main",
    }
    for proj in cfg["projects"]:
        want = expect[proj["name"]]
        got = proj["agent"]["options"]["provider"]
        names = [p["name"] for p in proj["agent"]["providers"]]
        if got != want:
            local.append(f"{label}/{proj['name']}: options.provider={got!r} 期望 {want!r}")
        if names != [want]:
            local.append(f"{label}/{proj['name']}: providers.name={names!r} 期望 [{want!r}]")

    failures.extend(local)
    head = "✅" if not local else "❌"
    print(f"  {head} {label}: provider 名 = {expect['codex']} / {expect['claude']}")
    for line in proc.stdout.splitlines():
        if "provider 名" in line:
            print("     " + line.strip())


print("用默认名(不设变量)与自定义名各跑一遍:")
run_case("默认", "", "")
run_case("自定义", "anyrouter", "imagic")
# 空白值必须回落到 main,不能写出 name = ""
run_case("空白值", "   ", "")

if failures:
    print("\n❌ 断言失败:")
    for item in failures:
        print("  - " + item)
    sys.exit(1)
print("\n✅ 全部通过:两处 provider 名始终一致")
