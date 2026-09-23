#!/usr/bin/env python3
"""把现有的一个 codex project 复制成 N 个新机器人 project(每个占一个飞书 App)。

为什么单独做这一步、而不是塞进 deploy-codex.sh:
    deploy-codex.sh 只处理"一个 codex + 一个 claude"两个 App。再要加 N 个机器人时,
    改的是同一份 config.toml,而要求是"新 project 的 agent 配置与现有 codex 完全一致" ——
    provider / sandbox_mode / 模型别名 / env 这些手抄一遍,抄错一处只会以"某个机器人
    行为不对"的形式暴露,那时早已离开部署现场。所以这里整块复制源 project 的正文,
    只改必须改的四处,并在落盘前用 TOML 解析器把新 project 与源 project 逐路径对比,
    差异超出预期就直接报错、不落盘。

只改这四处(其余逐字节保持源 project 的样子):
    name                codex → codex<N>   —— cc-connect 按 name 认 project
    codex_home          /workspace/codex-home<N>
    app_id / app_secret 每个新机器人一个飞书 App(一个 App 的长连接只能挂一个 project)
    丢弃 admin_from / allow_from / heartbeat:
        · admin_from / allow_from 是**按 App 隔离的 open_id**。新 App 里同一个人的
          open_id 与旧 App 不同,照抄下来的结果是"你的消息被静默忽略",不报任何错。
        · heartbeat 的 session_key 里带着旧机器人的会话与用户,照抄等于把 9 个机器人的
          心跳全推进同一个旧会话。
      两者都由部署后的独立步骤补:白名单 `set-allow-from.py --restart`,
      心跳 `set-heartbeat.py codex<N> --restart`。

为什么 codex_home 必须按 project 分开(与源 project 唯一的**有意差异**):
    cc-connect 在每次会话启动时都会往 $CODEX_HOME 写 auth.json 与 provider 配置
    (agent/codex/codex.go:499 调 ensureCodexAuth;agent/codex/provider_config.go:56 落盘)。
    9 个机器人共用一个 codex_home,就是 9 个进程并发改同一份 auth.json —— 写坏了以
    "某个机器人起不来"的形式出现;而且 /sessions 会把别的机器人的会话一起列出来。
    脚本每次运行都会把这条差异打印出来,不藏在日志里。

用法(容器内):
    python3 add-codex-bots.py bots9.env                # 落盘;已存在的 project 跳过
    python3 add-codex-bots.py bots9.env --dry-run      # 只打印将要做什么,不写盘
    python3 add-codex-bots.py bots9.env --update       # 已存在的只更新 App 凭证,其余不动
    python3 add-codex-bots.py bots9.env --restart      # 写完重启 cc-connect
    python3 add-codex-bots.py bots9.env --from codex2  # 换一个源 project

bots9.env 格式(本机 make-bots9-env.py 生成;键名里的序号决定 project 名):
    CODEX1_APP_ID=cli_xxx
    CODEX1_APP_SECRET=yyy
    ...
    CODEX9_APP_ID=cli_xxx
    CODEX9_APP_SECRET=yyy
    行首 # 是注释。等号后不要加行尾注释 —— 会被当成值的一部分。
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

# 输出流定死 UTF-8:容器 LANG 未必是 UTF-8。不定死的话,打印 ✅ 会在"配置已经写好
# 之后"抛 UnicodeEncodeError,脚本以非零码退出 —— 和真的失败分不开。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):   # 3.7 以下没有 reconfigure
        pass

DEFAULT_CONFIG = "/workspace/cc-connect/config.toml"
PROC_MATCH = "^/workspace/cc-connect/cc-connect"
HOME_PREFIX = "/workspace/codex-home"   # 源 project 用的是 /workspace/codex-home

# 键名即契约:CODEX<序号>_APP_ID / CODEX<序号>_APP_SECRET,序号决定 project 名 codex<N>。
# 不按文件里的顺序编号 —— 顺序会被人手重排,重排后静默换台机器人是最难查的一类故障。
ENV_KEY_RE = re.compile(r"^CODEX(?P<num>\d+)_(?P<field>APP_ID|APP_SECRET)$")

# 允许出现的差异(逐路径)。多一条、少一条都要报错 —— 这是本脚本存在的意义:
# 把「配置都同现有 codex 项目」从愿望变成可判定的事实。
WANT_CHANGED_KEYS = (
    ("name",),
    ("agent", "options", "codex_home"),
    ("platforms", "0", "options", "app_id"),
    ("platforms", "0", "options", "app_secret"),
)
WANT_REMOVED_PREFIXES = (
    ("admin_from",),
    ("heartbeat",),
    ("platforms", "0", "options", "allow_from"),
)


def parse_args():
    p = argparse.ArgumentParser(
        description="把现有 codex project 复制成 N 个新机器人 project",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("envfile", help="App 凭证文件(格式见文件头,本机 make-bots9-env.py 生成)")
    p.add_argument("--config", default=DEFAULT_CONFIG, help=f"配置文件(默认 {DEFAULT_CONFIG})")
    p.add_argument("--from", dest="source", default="codex", help="源 project 名(默认 codex)")
    p.add_argument("--update", action="store_true",
                   help="已存在的目标 project 只更新 app_id/app_secret,其余保持原样")
    p.add_argument("--restart", action="store_true", help="写完立即重启 cc-connect")
    p.add_argument("--dry-run", action="store_true", help="只报告将要做什么,不落盘")
    return p.parse_args()


def toml_load(text):
    """标准库 tomllib(3.11+);更老的 python 返回 None,由调用方降级为结构性自检"""
    try:
        import tomllib
    except ModuleNotFoundError:
        return None
    try:
        return tomllib.loads(text)
    except Exception as error:  # noqa: BLE001 —— 解析失败原因多样,统一报给用户
        raise SystemExit(f"❌ 现有配置文件不是合法 TOML,先修好再跑本脚本:\n   {error}")


def parse_env_file(path):
    """解析凭证文件,返回 {project 名: {"app_id": ..., "app_secret": ...}}(按序号排序)

    拒绝"只给一半"的条目:一个 App 只有 id 没有 secret 时,配置照样写得进去,
    cc-connect 要到建立长连接时才失败 —— 那时 9 个机器人已经部署了一半。
    """
    found = {}
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip().lstrip("﻿").rstrip("\r")
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"❌ {path} 第 {lineno} 行不是 KEY=VALUE: {line[:60]!r}")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        m = ENV_KEY_RE.match(key)
        if not m:
            raise SystemExit(
                f"❌ {path} 第 {lineno} 行的键名不认识: {key!r}\n"
                "   只认 CODEX<序号>_APP_ID / CODEX<序号>_APP_SECRET 两种。"
            )
        if not value:
            raise SystemExit(f"❌ {path} 第 {lineno} 行的 {key} 是空的")
        num = int(m.group("num"))
        entry = found.setdefault(num, {})
        field = "app_id" if m.group("field") == "APP_ID" else "app_secret"
        if field in entry:
            raise SystemExit(f"❌ {path}: CODEX{num} 的 {field} 出现了两次")
        entry[field] = value
    if not found:
        raise SystemExit(f"❌ {path} 里没有解析出任何 App 凭证")

    out = {}
    for num in sorted(found):
        entry = found[num]
        missing = [f for f in ("app_id", "app_secret") if f not in entry]
        if missing:
            raise SystemExit(f"❌ {path}: CODEX{num} 缺 {', '.join(missing)}"
                             "(App ID 与 App Secret 必须成对)")
        out[f"codex{num}"] = entry
    return out


def project_blocks(lines):
    """切出每个 [[projects]] 的文本区块(与 apply-providers.py / set-heartbeat.py 同一套规则)"""
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


def body_of(lines, block):
    """取出区块正文,并剥掉尾部空行与注释行。

    尾部注释属于**下一个** project(生成的配置里 "# Claude Code: ..." 就夹在
    codex 与 claude 之间),连着一块复制过去会变成每个新机器人都顶着别人的注释。
    """
    end = block["end"]
    while end > block["start"]:
        s = lines[end - 1].strip()
        if s and not s.startswith("#"):
            break
        end -= 1
    return lines[block["start"]:end]


def set_value(line, key, value):
    """保留原缩进,把 key = "..." 的值换掉"""
    pad = line[:len(line) - len(line.lstrip())]
    return f"{pad}{key} = {json.dumps(value, ensure_ascii=False)}"


def clone_body(src_body, project_name, app_id, app_secret, codex_home):
    """把源 project 正文复制成新 project 的正文,返回 (行列表, 改动说明列表)

    按"当前子表"逐行处理,不做整体正则替换 —— 表名决定语义:app_id 只该改平台凭证,
    而 admin_from 在别处可能有同名键。
    """
    out, notes = [], []
    table = "[[projects]]"
    have_home = False
    for ln in src_body:
        s = ln.strip()
        if s.startswith("["):
            table = s
            if table == "[projects.heartbeat]":
                # 心跳段(及其子键)自带旧机器人的 session_key,整段不要
                notes.append("丢弃 heartbeat 段")
                break
            out.append(ln)
            continue
        if s.startswith("#") or not s:
            out.append(ln)
            continue
        if table == "[[projects]]":
            if re.match(r"name\s*=", s):
                out.append(set_value(ln, "name", project_name))
                continue
            if re.match(r"admin_from\s*=", s):
                notes.append("丢弃 admin_from(open_id 按 App 隔离,抄过来会静默拦掉你)")
                continue
        elif table == "[projects.agent.options]":
            if re.match(r"codex_home\s*=", s):
                out.append(set_value(ln, "codex_home", codex_home))
                have_home = True
                continue
        elif table == "[projects.platforms.options]":
            if re.match(r"app_id\s*=", s):
                out.append(set_value(ln, "app_id", app_id))
                continue
            if re.match(r"app_secret\s*=", s):
                out.append(set_value(ln, "app_secret", app_secret))
                continue
            if re.match(r"allow_from\s*=", s):
                notes.append("丢弃 allow_from(同上;部署后用 set-allow-from.py 按新 App 回填)")
                continue
        out.append(ln)
    if not have_home:
        notes.append("⚠️ 源 project 没有 codex_home,这个机器人会与别人共用 ~/.codex")
    return out, notes


def update_credentials(lines, block, app_id, app_secret):
    """就地替换已存在 project 的 App 凭证,返回 (app_id 命中数, app_secret 命中数)"""
    hits, table = [0, 0], "[[projects]]"
    for i in range(block["start"], block["end"]):
        s = lines[i].strip()
        if s.startswith("["):
            table = s
            continue
        if table != "[projects.platforms.options]" or s.startswith("#"):
            continue
        if re.match(r"app_id\s*=", s):
            lines[i] = set_value(lines[i], "app_id", app_id)
            hits[0] += 1
        elif re.match(r"app_secret\s*=", s):
            lines[i] = set_value(lines[i], "app_secret", app_secret)
            hits[1] += 1
    return hits


def leaf_dict(node, prefix=()):
    """把嵌套 dict/list 摊平成 {路径元组: 叶子值}。路径里的下标用字符串,便于打印"""
    out = {}
    if isinstance(node, dict):
        for key, value in node.items():
            out.update(leaf_dict(value, prefix + (str(key),)))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            out.update(leaf_dict(value, prefix + (str(i),)))
    else:
        out[prefix] = node
    return out


def fmt_path(path):
    return ".".join(path) if path else "(根)"


def verify_clone(src_leaf, new_doc, name, app_id, app_secret, codex_home):
    """核对一个克隆:它只该在 WANT_* 声明的那几条路径上与源 project 不同。

    返回问题清单(空 = 通过)。源 project 以后多出别的 per-project 字段(比如新版本
    加的开关)不在允许表里,但它会被原样复制 —— 两边一致就不会出现在差异里,所以
    这张表不会随时间腐烂;真的是新增未复制的字段时,会以"多出了源 project 没有的
    xxx"被拦下,不静默吞掉。
    """
    new_leaf = leaf_dict(new_doc)
    removed = sorted(p for p in src_leaf if p not in new_leaf)
    added = sorted(p for p in new_leaf if p not in src_leaf)
    changed = sorted(p for p in src_leaf if p in new_leaf and src_leaf[p] != new_leaf[p])

    want_changed = {
        ("name",): name,
        ("agent", "options", "codex_home"): codex_home,
        ("platforms", "0", "options", "app_id"): app_id,
        ("platforms", "0", "options", "app_secret"): app_secret,
    }

    problems = []
    for path in changed:
        if path not in want_changed:
            problems.append(f"多改了 {fmt_path(path)}(源值 {src_leaf[path]!r} → 现值 {new_leaf[path]!r})")
        elif want_changed[path] != new_leaf[path]:
            problems.append(f"{fmt_path(path)} 的值不对:期望 {want_changed[path]!r},实得 {new_leaf[path]!r}")
    for path, value in want_changed.items():
        if path not in changed and src_leaf.get(path) != value:
            problems.append(f"该改的 {fmt_path(path)} 没改成 {value!r}(现值 {new_leaf.get(path)!r})")
    for path in added:
        problems.append(f"多出了源 project 没有的 {fmt_path(path)}(值 {new_leaf[path]!r})")
    for path in removed:
        if not any(path[:len(pre)] == pre for pre in WANT_REMOVED_PREFIXES):
            problems.append(f"不该丢的 {fmt_path(path)} 被丢掉了(源值 {src_leaf[path]!r})")
    for pre in WANT_REMOVED_PREFIXES:
        leftover = [p for p in src_leaf if p[:len(pre)] == pre and p in new_leaf]
        if leftover:
            problems.append(f"该丢的 {fmt_path(pre)} 还在:{fmt_path(leftover[0])}")
    return problems


def write_text_atomic_lines(path, text):
    """按 LF 写回。显式 newline="\\n" 是因为 Windows 上 write_text 默认写 CRLF ——
    容器里是 Linux 无所谓,但本机验证要在字节级比对"原有内容是新文件的前缀",
    行尾被换成 CRLF 会让那条断言失真成一个查不出原因的差异。
    """
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def cc_running():
    """cc-connect 是否在跑。只用它决定提示语,判错不影响配置正确性"""
    try:
        return subprocess.run(["pgrep", "-f", PROC_MATCH],
                              capture_output=True, text=True).returncode == 0
    except (FileNotFoundError, OSError):
        return False


def main():
    args = parse_args()
    env_path = pathlib.Path(args.envfile)
    if not env_path.is_file():
        raise SystemExit(f"❌ 找不到凭证文件: {env_path}")
    creds = parse_env_file(env_path)

    cfg = pathlib.Path(args.config)
    if not cfg.is_file():
        raise SystemExit(f"❌ 找不到配置文件: {cfg}")
    text = cfg.read_text(encoding="utf-8")
    doc = toml_load(text)
    lines = text.splitlines()
    blocks = {b["name"]: b for b in project_blocks(lines)}

    print(f"配置文件: {cfg}")
    print(f"凭证文件: {env_path}")
    print(f"源 project: {args.source}(复制整块正文,只改四处)")
    print(f"目标 project: {', '.join(creds)}")
    print()

    src_block = blocks.get(args.source)
    if src_block is None:
        have = ", ".join(n for n in blocks if n) or "(一个都没有)"
        raise SystemExit(f"❌ 配置里没有源 project {args.source!r};现有: {have}")

    if doc is None:
        print("  ⚠️ 当前 python 无 tomllib(需 3.11+),差异回验降级为结构性自检")
    else:
        src_doc = next((p for p in doc.get("projects", []) if p.get("name") == args.source), None)
        if src_doc is None:
            raise SystemExit(f"❌ TOML 解析出的 project 列表里没有 {args.source!r}(文本切分与解析不一致)")
        plats = src_doc.get("platforms") or []
        if len(plats) != 1 or (plats[0].get("type") or "") != "feishu":
            raise SystemExit(
                f"❌ 源 project {args.source!r} 的平台不是唯一一个 feishu"
                "(整块复制会把别的平台的凭证也一并搬过去,那种情况请手工处理)"
            )

    if args.source in creds:
        raise SystemExit(f"❌ 目标 project 里有和源同名的 {args.source!r}")

    # 逐条规划:新增 / 更新 / 跳过
    plans = []
    for name, entry in creds.items():
        suffix = name[len("codex"):] if name.startswith("codex") else name
        home = f"{HOME_PREFIX}{suffix}" if suffix.isdigit() else f"{HOME_PREFIX}-{name}"
        if name in blocks:
            plans.append({"name": name, "home": home, "kind": "update" if args.update else "skip", **entry})
        else:
            plans.append({"name": name, "home": home, "kind": "add", **entry})

    for plan in plans:
        mark = {"add": "新增", "update": "更新凭证", "skip": "已存在,跳过"}[plan["kind"]]
        print(f"  ▸ {plan['name']:<10} {mark:<12} App {plan['app_id'][:14]}…  home {plan['home']}")
    if any(p["kind"] == "skip" for p in plans):
        print("\n  ℹ️ 跳过的已存在 project 一字不动;要覆盖它们的 App 凭证,加 --update")
    print(f"\n  ⚠️ 有意差异:codex_home 按 project 分开({HOME_PREFIX}<N>)—— 共用一份会让")
    print("     多个进程并发改同一个 auth.json,且 /sessions 互相看到对方的会话。")
    print("  ⚠️ 有意差异:不继承 admin_from / allow_from / heartbeat —— 三者都绑在旧 App 的")
    print("     会话与用户上。部署后按提示补(见下方收尾说明)。")

    if not [p for p in plans if p["kind"] != "skip"]:
        print("\n✅ 无需改动(目标 project 都已存在)。")
        return 0
    if args.dry_run:
        print("\n--dry-run:未写盘")
        return 0

    # 已存在的走就地改凭证,其余的追加克隆正文
    for plan in [p for p in plans if p["kind"] == "update"]:
        hits = update_credentials(lines, blocks[plan["name"]], plan["app_id"], plan["app_secret"])
        if hits != [1, 1]:
            raise SystemExit(f"❌ {plan['name']}: App 凭证只替换到 {hits[0]} 处 app_id / "
                             f"{hits[1]} 处 app_secret(各应为 1)—— 它的 [[projects.platforms]] "
                             "结构可能被改过,请手工核对")

    new_lines = list(lines)
    for plan in [p for p in plans if p["kind"] == "add"]:
        body, notes = clone_body(body_of(lines, src_block), plan["name"],
                                 plan["app_id"], plan["app_secret"], plan["home"])
        print(f"  · {plan['name']}: {(';'.join(notes)) if notes else '无额外改动'}")
        new_lines += ["",
                      f"# {plan['name']} —— 由 add-codex-bots.py 从 {args.source} 复制"
                      "(改凭证:更新 bots9.env 后重跑 --update)"] + body
    if new_lines and new_lines[-1].strip():
        new_lines.append("")
    new_text = "\n".join(new_lines) + "\n"

    # 回验:解析得过,且每个新 project 与源 project 的差异恰好是允许的那几处
    doc2 = toml_load(new_text)
    if doc2 is None:
        print("\n  ⚠️ 当前 python 无 tomllib(需 3.11+),跳过 TOML 回验")
    else:
        by_name = {p.get("name"): p for p in doc2.get("projects", [])}
        src_leaf = leaf_dict(next(p for p in doc2["projects"] if p.get("name") == args.source))
        plan_by_name = {p["name"]: p for p in plans}
        bad = 0
        for plan in [p for p in plans if p["kind"] == "add"]:
            got = by_name.get(plan["name"])
            if got is None:
                print(f"  ❌ {plan['name']} 没写进配置")
                bad += 1
                continue
            problems = verify_clone(src_leaf, got, plan["name"],
                                    plan["app_id"], plan["app_secret"], plan["home"])
            if problems:
                bad += 1
                print(f"  ❌ {plan['name']} 与 {args.source} 的差异不符合预期:")
                for p in problems:
                    print(f"       · {p}")
        for plan in [p for p in plans if p["kind"] == "update"]:
            got = by_name.get(plan["name"]) or {}
            opt = ((got.get("platforms") or [{}])[0].get("options") or {})
            if opt.get("app_id") != plan["app_id"] or opt.get("app_secret") != plan["app_secret"]:
                print(f"  ❌ {plan['name']} 的 App 凭证没更新成期望值")
                bad += 1
        if bad:
            raise SystemExit("❌ 回验失败,未写盘(现有配置一字未动)")
        print(f"\n  ✅ TOML 解析通过:{len([p for p in plans if p['kind'] == 'add'])} 个新 project "
              f"与 {args.source} 逐路径比对,差异仅限上面列出的四处")

    # 先备份:含密钥的配置改坏了能立刻还原,不用重新部署
    backup = cfg.with_suffix(cfg.suffix + ".pre-bots")
    write_text_atomic_lines(backup, text)
    write_text_atomic_lines(cfg, new_text)
    try:
        cfg.chmod(0o600)    # 含密钥,保持创建时的收紧权限
    except OSError:
        pass

    added = [p["name"] for p in plans if p["kind"] == "add"]
    updated = [p["name"] for p in plans if p["kind"] == "update"]
    print(f"\n  ✅ 已写入 {cfg}")
    print(f"     备份: {backup}")
    print(f"     新增: {', '.join(added) or '(无)'}")
    if updated:
        print(f"     更新凭证: {', '.join(updated)}")

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
            print(f"  ⚠️ 配置改动需重启才生效: pkill -f {PROC_MATCH!r}")
            print("     (会打断正在进行的对话,故没默认做;watchdog 10 秒内自动拉起)")
    else:
        print("  ℹ️ cc-connect 当前未在运行,下次启动时生效")

    print()
    print("收尾(重启之后做):")
    print("  1. 在飞书里逐个给新机器人发一条消息 —— 没收到过消息的机器人在 cc-connect 里没有会话")
    print("  2. 回填白名单:python3 set-allow-from.py --restart")
    print("     新 App 里你的 open_id 与旧 App 不同,不填等于谁都能用;想先确认自己的 ID 就发 /whoami")
    print("  3. 配心跳(可选):python3 set-heartbeat.py codex1 --restart(逐个来)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
