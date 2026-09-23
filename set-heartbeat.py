#!/usr/bin/env python3
"""给某个 project 配置 cc-connect 心跳([projects.heartbeat])。

为什么单独做这一步、而不是塞进 deploy-codex.sh:
    session_key 是心跳的必填项,取值形如 feishu:oc_<会话ID>:ou_<你的open_id>,
    其中"会话ID"只有机器人真收到过消息才存在 —— 部署当下根本无从得知。
    所以部署脚本不生成心跳段,改由本脚本在部署之后按实际会话补上。

会话键从哪来:
    cc-connect 把会话落盘到 {data_dir}/sessions/{project}_{work_dir哈希}.json。
    注意 sessions 字段**不是** {会话键: 会话对象} —— 它是以内部会话 ID(s1/s4
    这种,见 core/session.go 的 nextID 与 sm.sessions[sid])为键的,会话键压根
    不在那里。会话键出现在 user_meta(来源 UpdateUserMeta(sessionKey, ...))、
    active_session、user_sessions 的键上,但这几个字段的位置跨版本挪动过,
    所以本脚本改为扫全文件里所有长得像会话键的字符串,不赌它落在哪个字段。
    会话键本身不写日志,这份快照是唯一可靠来源。

用法(容器内):
    python3 set-heartbeat.py                    # 列出各 project 已发现的会话键,不改配置
    python3 set-heartbeat.py codex              # 给 codex 启用心跳(会话键自动发现)
    python3 set-heartbeat.py codex1 codex2      # 一次配多个(逐台各取自己的会话键,一次重启)
    python3 set-heartbeat.py codex1 codex2 --like codex        # 参数照抄 codex 那台
    python3 set-heartbeat.py codex1 codex2 --like codex --dry-run   # 只报告,不落盘
    python3 set-heartbeat.py codex --off        # 关闭(保留配置段,便于再开)
    python3 set-heartbeat.py codex --key feishu:oc_xxx:ou_yyy   # 显式指定,跳过自动发现
    python3 set-heartbeat.py codex --interval 60 --prompt "检查未完成任务"
    python3 set-heartbeat.py codex --restart    # 写完立即重启 cc-connect 使配置生效

--like <project>:把那个 project 心跳段里的参数(interval_mins / timeout_mins /
    only_when_idle / silent / prompt)原样抄给目标,只把 session_key 换成目标自己的。
    这是“多台机器人要与现有那台完全一致”的正确做法:中文提示词经飞书转发会变成
    U+FFFD,手抄参数抄错一位又不会报任何错。enabled 恒为 true(要关用 --off)。
--key 只能配单个 project:每个机器人的会话键不同,一个键套不到多台上。
--silent / --only-when-idle 不写就沿用 cc-connect 的默认值,不会硬塞进配置。

安全约定:改写前先用 TOML 解析器回验,解析不过绝不落盘 —— 配置写坏会让
    cc-connect 起不来,那比"心跳没开"严重得多。
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import time

# 输出流定死 UTF-8:本脚本要在容器(LANG 未必是 UTF-8)和用户本机(Windows 上
# python 默认按 GBK 编码 stdout)都能跑。不定死的话,打印 ✅ 会抛 UnicodeEncodeError,
# 而那往往发生在"配置已经写好之后" —— 脚本以非零码退出,让人误以为没写成功。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):   # 3.7 以下没有 reconfigure
        pass

DEFAULT_CONFIG = "/workspace/cc-connect/config.toml"
PROC_MATCH = "^/workspace/cc-connect/cc-connect"


def parse_args():
    p = argparse.ArgumentParser(
        description="配置 cc-connect 心跳(会话键自动发现)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("projects", nargs="*",
                   help="目标 project 名,可给多个(如 codex1 codex2);省略则只列出会话键")
    p.add_argument("--config", default=DEFAULT_CONFIG, help=f"配置文件路径(默认 {DEFAULT_CONFIG})")
    p.add_argument("--key", default="", help="显式指定 session_key,跳过自动发现(只能配单个 project)")
    p.add_argument("--like", default="", help="照抄该 project 的心跳参数,只换 session_key")
    p.add_argument("--dry-run", action="store_true", help="只报告将要写什么,不落盘")
    p.add_argument("--off", action="store_true", help="关闭心跳(enabled = false)")
    p.add_argument("--interval", type=int, default=0, help="间隔分钟数(默认 30)")
    p.add_argument("--prompt", default="", help="心跳提示词;留空则读 work_dir 下的 HEARTBEAT.md")
    p.add_argument("--timeout", type=int, default=0, help="单次最长执行分钟数(默认 30)")
    # 用一对 store_true/store_false 而不是 BooleanOptionalAction:后者要 python 3.9+,
    # 而容器里的 python3 版本不由我们决定,这个脚本不能因为一个开关用不了就整个崩掉。
    # default=None 表示"没指定",此时不往配置里写该项,沿用 cc-connect 的默认值。
    g_sil = p.add_mutually_exclusive_group()
    g_sil.add_argument("--silent", dest="silent", action="store_true", default=None,
                       help="心跳结果静默,不推送到聊天")
    g_sil.add_argument("--no-silent", dest="silent", action="store_false",
                       help="心跳结果推送到聊天")
    g_idle = p.add_mutually_exclusive_group()
    g_idle.add_argument("--only-when-idle", dest="only_when_idle", action="store_true", default=None,
                        help="仅在空闲时触发")
    g_idle.add_argument("--no-only-when-idle", dest="only_when_idle", action="store_false",
                        help="不限制空闲,到点就触发")
    p.add_argument("--restart", action="store_true", help="写完立即重启 cc-connect")
    return p.parse_args()


# ---------- 读配置 ----------

def toml_load(text):
    """优先用标准库 tomllib(3.11+);更老的 python 返回 None,由调用方降级"""
    try:
        import tomllib
    except ModuleNotFoundError:
        return None
    try:
        return tomllib.loads(text)
    except Exception as error:  # noqa: BLE001 —— 解析失败原因多样,统一报给用户
        raise SystemExit(f"❌ 现有配置文件不是合法 TOML,先修好再跑本脚本:\n   {error}")


def find_data_dir(text, doc):
    """取 data_dir;缺省时按 cc-connect 的规则回落到 ~/.cc-connect"""
    if doc is not None:
        value = (doc.get("data_dir") or "").strip()
    else:
        m = re.search(r'^\s*data_dir\s*=\s*"([^"]*)"', text, re.M)
        value = m.group(1).strip() if m else ""
    if value:
        return value
    return os.path.join(os.path.expanduser("~"), ".cc-connect")


def project_blocks(lines, doc):
    """切出每个 [[projects]] 的文本区块。

    doc 可用时以解析出的 name 为准(权威),否则退回扫 `name = "..."`。
    name 只认区块里第一个 `name =` —— 子表里的 name(如 providers.name)
    缩进更深,但简单起见还是靠"第一个"这条规则,因为生成的配置里
    project 的 name 一定紧跟 [[projects]]。
    """
    starts = [i for i, ln in enumerate(lines) if ln.strip() == "[[projects]]"]
    blocks = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        name = ""
        for ln in lines[start + 1:end]:
            s = ln.strip()
            if s.startswith("["):       # 越过子表头就不再找了,避免误取 providers.name
                break
            m = re.match(r'name\s*=\s*"([^"]*)"', s)
            if m:
                name = m.group(1)
                break
        blocks.append({"name": name, "start": start, "end": end})
    return blocks


def heartbeat_of(doc, name):
    """取某 project 的 heartbeat 段(供 --like 照抄)。

    返回:dict(有段,可能为空) / {} (有 project 但没段) / None(没有这个 project)。
    三种情况要分开 —— 把"没有这个 project"和"有这个 project 但没配心跳"混成一个
    错误提示,会让人以为名字写错了。
    """
    for proj in (doc or {}).get("projects", []):
        if proj.get("name") == name:
            return proj.get("heartbeat") or {}
    return None


def prev_heartbeat_key(doc, name):
    """取该 project 现有心跳段的 session_key(--off 时保留它,重开不用再发现一次)"""
    return (heartbeat_of(doc, name) or {}).get("session_key") or ""


def _iter_strings(node):
    """深度遍历 JSON,产出其中所有字符串(映射的键与值都算)"""
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str):
                yield key
            yield from _iter_strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from _iter_strings(value)
    elif isinstance(node, str):
        yield node


def _looks_like_session_key(value):
    """形如 平台:会话:用户 的才算会话键。

    首段必须是纯字母(平台名)。这一条不是装饰:时间戳 2026-09-19T18:46:00Z 也含
    两个冒号,只按冒号个数筛就会把它当会话键收进来 —— 那种东西写进配置,心跳会
    一直发不出去,而且不报错。
    """
    if not isinstance(value, str):
        return False
    parts = value.split(":")
    return len(parts) >= 3 and parts[0].isalpha() and all(parts)


def _mtime_text(path):
    try:
        stamp = path.stat().st_mtime
    except OSError:
        return ""
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(stamp))


def discover_sessions(data_dir, project):
    """返回该 project 的会话键列表: [(最近活动, 会话键, 来源文件), ...]

    文件名规则见 cmd/cc-connect/main.go 的 sessionStorePath:
        {data_dir}/sessions/{project}_{sha256(work_dir)前8位}.json
    这里不重算哈希(work_dir 可能被 project_state 覆盖过),直接用 glob 匹配 ——
    比复刻一遍哈希逻辑稳。

    旧实现读的是 sessions 表、并按 key.count(":") < 2 过滤,结果是**永远返回空**,
    现场表现成"没有会话" —— 因为那张表的键是内部 ID(s4),一条都不含冒号。
    现在改成全文件扫描,理由见文件头的"会话键从哪来"。
    """
    cands = []
    sess_dir = pathlib.Path(data_dir) / "sessions"
    if sess_dir.is_dir():
        cands += sorted(sess_dir.glob(f"{project}_*.json"))
        cands += [sess_dir / f"{project}.json"]
    # 兼容更老的位置:{data_dir}/{project}*.json(见 sessionStorePath 的 legacy 分支)
    cands += sorted(pathlib.Path(data_dir).glob(f"{project}_*.json"))
    for path in cands:
        if not path.is_file():
            continue
        try:
            snapshot = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"  ⚠️ 跳过读不了的会话文件 {path}: {error}")
            continue
        keys = {s for s in _iter_strings(snapshot) if _looks_like_session_key(s)}
        if not keys:
            continue
        # 快照里没有"会话键 → 最近活动"的对应关系:UserMeta 只有用户名/群名两个
        # 字段,带 updated_at 的 sessions 表又是按内部 ID 索引的,两边的键对不上。
        # 所以用文件修改时间统一代表这个文件里的会话。同一文件内的先后无从区分,
        # 多了一个就交给调用方要求显式 --key。
        stamp = _mtime_text(path)
        return [(stamp, key, path) for key in sorted(keys)]
    return []


# ---------- 写配置 ----------

def build_heartbeat(key, enabled, interval, prompt, timeout, silent, only_when_idle):
    """生成 [projects.heartbeat] 段文本(含前置空行),缩进 2 空格与 project 同级"""
    pad = "  "
    lines = [
        f"{pad}[projects.heartbeat]",
        f"{pad}  enabled = {'true' if enabled else 'false'}",
        f'{pad}  session_key = "{key}"',
    ]
    if interval:
        lines.append(f"{pad}  interval_mins = {interval}")
    if timeout:
        lines.append(f"{pad}  timeout_mins = {timeout}")
    # 两个开关必须用 `is not None` 判:False 是合法取值,写成 if silent 会把它漏掉,
    # 结果就是"想关掉的没关掉",而且这种错不报错、只在行为上体现。
    if only_when_idle is not None:
        lines.append(f"{pad}  only_when_idle = {'true' if only_when_idle else 'false'}")
    if silent is not None:
        lines.append(f"{pad}  silent = {'true' if silent else 'false'}")
    if prompt:
        # json.dumps 的转义规则与 TOML 基本字符串兼容,且能正确处理换行/引号
        lines.append(f"{pad}  prompt = {json.dumps(prompt, ensure_ascii=False)}")
    return ["", *lines]


def merge_opts(args, like):
    """把命令行参数与 --like 源合并:命令行优先,源补齐,都没有则留 0/None(不写进配置)。

    interval / timeout 用 `or` 合并而两个开关用 `is not None` —— 前者 0 表示"没指定",
    后者 False 是合法取值。混用会让 --no-silent 被源里的 true 顶掉。
    """
    return {
        "interval": args.interval or like.get("interval_mins") or 0,
        "timeout": args.timeout or like.get("timeout_mins") or 0,
        "prompt": args.prompt or like.get("prompt", ""),
        "only_when_idle": (args.only_when_idle if args.only_when_idle is not None
                           else like.get("only_when_idle")),
        "silent": args.silent if args.silent is not None else like.get("silent"),
    }


def effective_extras(opts):
    """回验要核的额外开关。值为 None = 最终没定,不写进配置也不核。"""
    return {"silent": opts["silent"], "only_when_idle": opts["only_when_idle"]}


def describe_opts(opts):
    """把"这次实际写了什么"写成一行;没定的键明说沿用 cc-connect 默认值,不替它声张"""
    parts = [f"interval_mins={opts['interval'] or 30}", f"timeout_mins={opts['timeout'] or 30}"]
    for name in ("only_when_idle", "silent"):
        parts.append(f"{name}={opts[name]}" if opts[name] is not None
                     else f"{name}=(未指定,沿用默认)")
    parts.append("prompt=" + (json.dumps(opts["prompt"], ensure_ascii=False) if opts["prompt"]
                              else "(未设,读 work_dir/HEARTBEAT.md)"))
    return ", ".join(parts)


def collect_targets(blocks, names):
    """按给定名字取区块;名字不存在就带着可选列表停下(不猜、不改)"""
    out = []
    for name in names:
        block = next((b for b in blocks if b["name"] == name), None)
        if block is None:
            raise SystemExit(f"❌ 没有名为 {name!r} 的 project;可选: "
                             + ", ".join(b["name"] for b in blocks))
        out.append(block)
    return out


def resolve_key(args, data_dir, block, prev_key=""):
    """定这个 project 的会话键,返回 (键, 来源说明)。

    --off 优先沿用原值,其次 --key;开启时 --key 优先,否则自动发现。
    发现到多个候选时**不挑一个** —— 选错了心跳会发到别人/别的会话里,而且不报错。
    """
    name = block["name"]
    if args.off:
        key = args.key or prev_key
        if not key:
            raise SystemExit(f"❌ 关闭 {name} 时原配置里没有 session_key,也没给 --key;"
                             "直接删掉那段配置即可")
        return key, "(沿用原值)"
    if args.key:
        return args.key, "(显式指定)"
    found = discover_sessions(data_dir, name)
    if not found:
        raise SystemExit(
            f"❌ 没发现 {name} 的任何会话。\n"
            "   心跳的 session_key 必须等于机器人实际在用的会话键,猜不出来。\n"
            "   请先在飞书给该机器人发一条消息,再重跑本脚本。"
        )
    keys = [k for _, k, _ in found]
    if len(keys) > 1:
        print(f"  ⚠️ {name} 发现 {len(keys)} 个会话,无法确定该用哪个 —— 用 --key 指定其一:")
        for updated, key, path in found:
            print(f"      {key}    (最近活动 {updated or '未知'}, {path.name})")
        raise SystemExit(f"  例如: python3 set-heartbeat.py {name} --key {keys[0]}")
    return keys[0], f"(来自 {found[0][2].name})"


def write_text_lf(path, text):
    """按 LF 写回。显式 newline="\\n" 是因为 Windows 上 write_text 默认写 CRLF ——
    配置的行尾不该随"改它的机器"而变;本机验证要在字节层面比对改写前后的差异,
    行尾被悄悄换掉会让那种断言失真成一个查不出原因的差异。
    """
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def splice(lines, block, heartbeat):
    """在目标 project 区块内替换或追加心跳段,返回新行列表"""
    # 心跳必须是该 project 的最后一个子表:插在区块末尾就不会被后续表头抢走归属
    end = block["end"]
    while end > block["start"] and not lines[end - 1].strip():
        end -= 1     # 回退掉块尾空行,把心跳放在紧贴最后一行有效内容之后

    existing = None
    for i in range(block["start"], block["end"]):
        if lines[i].strip() == "[projects.heartbeat]":
            existing = i
            break

    if existing is not None:
        # 旧段从表头开始,吃掉它直到下一个表头或区块结束
        stop = existing + 1
        while stop < block["end"] and not lines[stop].strip().startswith("["):
            stop += 1
        while stop < block["end"] and not lines[stop].strip():
            stop += 1
        return lines[:existing] + heartbeat + lines[stop:]
    return lines[:end] + heartbeat + lines[end:]


def verify(text, project, expect_key, enabled, extras=None):
    """落盘前回验:解析得过,且值确实落在目标 project 上。
    extras 里值为 None 的键跳过 —— 那是"没指定、沿用默认"的意思。"""
    doc = toml_load(text)
    if doc is None:
        return "跳过回验(当前 python 无 tomllib,需 3.11+):改动已做结构性自检"
    projs = {p.get("name"): p for p in doc.get("projects", [])}
    if project not in projs:
        raise SystemExit(f"❌ 回验失败:改写后找不到 project {project!r}")
    hb = projs[project].get("heartbeat")
    if not hb:
        raise SystemExit(f"❌ 回验失败:{project} 下没有解析出 heartbeat 段")
    if hb.get("session_key") != expect_key:
        raise SystemExit(f"❌ 回验失败:session_key 期望 {expect_key!r},实得 {hb.get('session_key')!r}")
    if hb.get("enabled") is not enabled:
        raise SystemExit(f"❌ 回验失败:enabled 期望 {enabled},实得 {hb.get('enabled')}")
    for k, want in (extras or {}).items():
        if want is not None and hb.get(k) != want:
            raise SystemExit(f"❌ 回验失败:{project}.heartbeat.{k} 期望 {want!r},实得 {hb.get(k)!r}")
    return ""


def main():
    args = parse_args()
    cfg = pathlib.Path(args.config)
    if not cfg.is_file():
        raise SystemExit(f"❌ 找不到配置文件: {cfg}")

    text = cfg.read_text(encoding="utf-8")
    doc = toml_load(text)
    lines = text.splitlines()
    blocks = project_blocks(lines, doc)
    if not blocks:
        raise SystemExit(f"❌ {cfg} 里没有 [[projects]] 段")
    data_dir = find_data_dir(text, doc)

    # 无参数 = 只读巡检:把各 project 能发现的会话键列出来
    if not args.projects:
        print(f"配置文件: {cfg}")
        print(f"数据目录: {data_dir}")
        print()
        for b in blocks:
            found = discover_sessions(data_dir, b["name"])
            if not found:
                print(f"  {b['name']}: (没有会话 —— 先给机器人发一条消息)")
                continue
            print(f"  {b['name']}:")
            for updated, key, _ in found:
                print(f"    {key}    (最近活动 {updated or '未知'})")
        print()
        print("启用心跳: python3 set-heartbeat.py <project> [<project> ...]")
        print("照抄现有那台: python3 set-heartbeat.py codex1 codex2 --like codex")
        return 0

    targets = collect_targets(blocks, args.projects)
    if args.key and len(targets) > 1:
        raise SystemExit("❌ --key 只能配单个 project:每个机器人的会话键不同,"
                         "一个键套不到多台上。")
    if args.like and args.off:
        raise SystemExit("❌ --off 与 --like 不能同时用:前者关心跳,后者照抄源项目的开启参数。")

    # --like:照抄源 project 的心跳参数(只换 session_key)
    like = {}
    if args.like:
        if doc is None:
            raise SystemExit("❌ --like 要用 TOML 解析器读源 project 的 heartbeat 段,"
                             "而当前 python 没有 tomllib(需 3.11+)。")
        got = heartbeat_of(doc, args.like)
        if got is None:
            raise SystemExit(f"❌ 没有名为 {args.like!r} 的 project;可选: "
                             + ", ".join(b["name"] for b in blocks))
        if not got:
            raise SystemExit(f"❌ {args.like} 没有 [projects.heartbeat] 段,没有可照抄的参数;"
                             "请用 --interval / --prompt 等直接指定。")
        like = got
    opts = merge_opts(args, like)

    # 逐台定会话键。任何一台定不下来就整体停手 —— 半批写入会让"配了几台"变成
    # 要人肉核对的事,而这正是本脚本要消灭的东西。
    plans = []
    for block in targets:
        key, source = resolve_key(args, data_dir, block, prev_heartbeat_key(doc, block["name"]))
        plans.append({"name": block["name"], "key": key, "source": source})
        print(f"  ▸ {block['name']:<12} {key}   {source}")
    print()

    # 倒序改:插入新行会让**后面**区块的行号偏移,从后往前处理就不必重算区间
    by_name = {b["name"]: b for b in targets}
    new_lines = list(lines)
    for plan in sorted(plans, key=lambda p: by_name[p["name"]]["start"], reverse=True):
        hb = build_heartbeat(plan["key"], not args.off, opts["interval"], opts["prompt"],
                             opts["timeout"], opts["silent"], opts["only_when_idle"])
        new_lines = splice(new_lines, by_name[plan["name"]], hb)
    new_text = "\n".join(new_lines) + "\n"

    # 落盘前回验:解析得过,且每一台的值都确实落在它自己那个 project 上
    notes = []
    for plan in plans:
        note = verify(new_text, plan["name"], plan["key"], not args.off,
                      extras=effective_extras(opts))
        if note:
            notes.append(note)
    if args.dry_run:
        print(f"  --dry-run:未写盘(将要写 {len(plans)} 个 project 的 [projects.heartbeat] 段)")
        print(f"     参数:{describe_opts(opts)}")
        for note in notes:
            print(f"     ⚠️ {note}")
        return 0

    # 先备份:改坏了能立刻还原,不用重新部署
    backup = cfg.with_suffix(cfg.suffix + ".bak")
    write_text_lf(backup, text)
    write_text_lf(cfg, new_text)
    try:
        cfg.chmod(0o600)    # 含密钥,保持创建时的收紧权限
    except OSError:
        pass

    print(f"  ✅ 已{'关闭' if args.off else '启用'} {len(plans)} 个 project 的心跳")
    for plan in plans:
        print(f"     · {plan['name']:<12} session_key = {plan['key']}")
    print(f"     参数{'（照抄自 ' + args.like + '）' if args.like else ''}:"
          f"{describe_opts(opts)}")
    for note in notes:
        print(f"     ⚠️ {note}")
    print(f"     备份: {backup}")
    return report_restart(args)


def cc_running():
    """cc-connect 是否在跑。

    只用它决定提示语,判错不影响配置正确性 —— 所以 pgrep 不存在时按"未运行"返回,
    绝不让脚本崩在收尾处:那会让一次成功的改写以非零码结束,和真的失败分不开。
    (容器是 Linux 一定有 pgrep;本机可能是 Windows/Git Bash。)
    """
    try:
        return subprocess.run(["pgrep", "-f", PROC_MATCH],
                              capture_output=True, text=True).returncode == 0
    except (FileNotFoundError, OSError):
        return False


def report_restart(args):
    """配置改动要重启才生效;是否代劳由 --restart 决定"""
    if not cc_running():
        print("  ℹ️ cc-connect 当前未在运行,下次启动时生效")
        return 0
    if args.restart:
        try:
            subprocess.run(["pkill", "-f", PROC_MATCH], check=False)
            print("  🔄 已重启 cc-connect(watchdog 会在 10 秒内自动拉起)")
        except (FileNotFoundError, OSError):
            print("  ⚠️ 找不到 pkill,请手工重启(见下方命令)")
            args.restart = False
    if not args.restart:
        print()
        print("  ⚠️ 配置改动需重启 cc-connect 才生效。加 --restart 可让本脚本代劳,")
        print("     或自己执行(会打断正在进行的对话,故没默认做):")
        print(f"     pkill -f {PROC_MATCH!r}   # watchdog 10 秒内自动拉起")
    print()
    print("  生效后可在飞书里用 /heartbeat 查看状态;子命令 pause / resume / run 控制它。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
