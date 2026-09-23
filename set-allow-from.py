#!/usr/bin/env python3
"""给 project 回填 allow_from / admin_from(open_id 自动发现)。

为什么需要它:
    飞书的 open_id **按 App 隔离** —— 同一个人,在每个 App 里是不同的 ou_xxx。
    所以 add-codex-bots.py 克隆出来的新机器人不能继承旧项目的白名单(照抄的结果是
    "你的消息被静默忽略",不报任何错),deploy-codex.sh 生成的新机器人同样留空。
    空的 allow_from 在 cc-connect 里等于**不设限**(core/message.go:82 的 AllowList),
    谁都能用;admin_from 为空则特权命令(/dir /shell /restart /cron addexec)对谁都不可用。

open_id 从哪来:
    从会话快照里反查,不自造也不人工抄。cc-connect 把会话落在
    {data_dir}/sessions/{project}_{work_dir哈希前8位}.json,会话键形如
    feishu:<chatID>:<userID>(platform/feishu/feishu.go:3626 的 makeSessionKey),
    最后一段就是发消息那个人的 ID —— 正是 allow_from 要比对的值(AllowList 拿事件里的
    sender id 比字符串,两者取值同源,所以类型必然一致)。
    扫描方式与 set-heartbeat.py 相同:全文件找长得像会话键的字符串,不赌它落在哪个字段。

两个键的语义(见 config.example.toml):
    allow_from  能跟这个机器人对话的人(逗号分隔;"*" 或留空 = 不设限)
    admin_from  能执行特权命令的人;**必须写在 [[projects]] 这一层**

用法(容器内):
    python3 set-allow-from.py                      # 巡检:列出每个 project 发现到的 ID,不改配置
    python3 set-allow-from.py --apply              # 给"没设白名单的 feishu project"回填
    python3 set-allow-from.py --apply --restart    # 回填并重启 cc-connect
    python3 set-allow-from.py codex3 codex4 --apply        # 只处理指定的 project
    python3 set-allow-from.py --id ou_xxx --apply          # 显式指定,跳过自动发现
    python3 set-allow-from.py --force --apply              # 已有白名单也覆盖

前置条件:先让机器人在飞书里收到过你的消息 —— 没收到过就没有会话,自然无处发现 ID。
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

# 飞书的 ID 前缀:open_id = ou_,union_id = on_。别的形状(会话键被 shareSessionInChannel
# 压成 feishu:<chatID> 两段、或 threadIsolation 下的 feishu:<chatID>:root:<id>)
# 都不是用户 ID —— 发现不了就明说,不去猜一个塞进白名单。
USER_ID_RE = re.compile(r"^(ou_|on_)[A-Za-z0-9_-]+$")


def parse_args():
    p = argparse.ArgumentParser(
        description="回填 project 的 allow_from / admin_from(open_id 自动发现)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("projects", nargs="*", help="目标 project 名;省略 = 所有没设白名单的 feishu project")
    p.add_argument("--config", default=DEFAULT_CONFIG, help=f"配置文件(默认 {DEFAULT_CONFIG})")
    p.add_argument("--id", default="", help="显式指定 open_id,跳过自动发现")
    p.add_argument("--apply", action="store_true", help="真的写盘(不加只巡检、不改配置)")
    p.add_argument("--force", action="store_true", help="已有 allow_from 的 project 也覆盖")
    p.add_argument("--restart", action="store_true", help="写完立即重启 cc-connect")
    return p.parse_args()


def toml_load(text):
    """标准库 tomllib(3.11+);缺了直接停,不降级 —— 见 main() 里的说明"""
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
    return value or str(pathlib.Path.home() / ".cc-connect")


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


def _session_key_user(value):
    """会话键 → 用户 ID;不像会话键、或取不到用户段时返回 ""。

    首段必须是纯字母(平台名)。这一条不是装饰:时间戳 2026-09-19T18:46:00Z 也含冒号,
    只按冒号个数筛就会把它当会话键收进来。
    """
    if not isinstance(value, str):
        return ""
    parts = value.split(":")
    if len(parts) < 3 or not parts[0].isalpha() or not all(parts):
        return ""
    return parts[-1] if USER_ID_RE.match(parts[-1]) else ""


def discover_owners(data_dir, project):
    """返回 [(用户 ID, 会话键, 来源文件), ...](按 ID 去重)

    一个文件里可能有多个人对话过(群里),这时全部返回让调用方决定要不要显式指定 ——
    自己挑一个塞进白名单,是"静默锁掉别人"的经典做法。
    """
    sess_dir = pathlib.Path(data_dir) / "sessions"
    cands = []
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
        found = {}
        for value in _iter_strings(snapshot):
            uid = _session_key_user(value)
            if uid:
                found.setdefault(uid, value)
        if found:
            return [(uid, key, path) for uid, key in sorted(found.items())]
    return []


def platform_of(doc, name):
    """取该 project 的 feishu 平台配置 dict;没有则返回 None"""
    proj = next((p for p in (doc or {}).get("projects", []) if p.get("name") == name), None)
    if proj is None:
        return None
    for plat in proj.get("platforms") or []:
        if (plat.get("type") or "") == "feishu":
            return plat
    return None


def set_key_in_table(lines, block, table, key, value):
    """在指定子表里写 key = value:有就替换,没有就追加到该子表末尾。返回是否有改动。

    追加位置选**子表末尾**而不是紧贴表头:生成的配置里 app_secret 是这一段的收尾,
    白名单跟在它后面,diff 读起来才是一段落一件事。
    """
    header = None
    for i in range(block["start"], block["end"]):
        if lines[i].strip() == table:
            header = i
            break
    if header is None:
        return False
    pad = lines[header][:len(lines[header]) - len(lines[header].lstrip())] + "  "
    stop = block["end"]
    for i in range(header + 1, block["end"]):
        s = lines[i].strip()
        if s.startswith("["):
            stop = i
            break
    last = header
    for i in range(header + 1, stop):
        s = lines[i].strip()
        if s.startswith("#") or not s:
            continue
        if re.match(rf"{key}\s*=", s):
            lines[i] = f"{pad}{key} = {json.dumps(value, ensure_ascii=False)}"
            return True
        last = i
    lines.insert(last + 1, f"{pad}{key} = {json.dumps(value, ensure_ascii=False)}")
    return True


def set_key_at_project_level(lines, block, key, value):
    """在 [[projects]] 顶层写 key = value(admin_from 必须在这一层)。

    扫到第一个 `[` 就停 —— 那个表头属于本区块,不会越到下一个 project 去。
    """
    stop, last = block["end"], block["start"]
    for i in range(block["start"] + 1, block["end"]):
        s = lines[i].strip()
        if s.startswith("["):
            stop = i
            break
    for i in range(block["start"] + 1, stop):
        s = lines[i].strip()
        if s.startswith("#") or not s:
            continue
        if re.match(rf"{key}\s*=", s):
            pad = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            lines[i] = f"{pad}{key} = {json.dumps(value, ensure_ascii=False)}"
            return True
        last = i
    lines.insert(last + 1, f"{key} = {json.dumps(value, ensure_ascii=False)}")
    return True


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
    cfg = pathlib.Path(args.config)
    if not cfg.is_file():
        raise SystemExit(f"❌ 找不到配置文件: {cfg}")
    text = cfg.read_text(encoding="utf-8")
    doc = toml_load(text)
    if doc is None:
        raise SystemExit(
            "❌ 本脚本需要 tomllib(python 3.11+),不降级:\n"
            "   白名单写错会让机器人连你都不理,而这不会有任何报错 —— 宁可在这里停住。"
        )
    lines = text.splitlines()
    blocks = {b["name"]: b for b in project_blocks(lines)}
    data_dir = find_data_dir(text, doc)

    explicit = (args.id or "").strip()
    if explicit and not USER_ID_RE.match(explicit):
        raise SystemExit(f"❌ --id 不像飞书用户 ID(应以 ou_ 或 on_ 开头): {explicit!r}")

    # 目标 = 显式列出的 project,或"所有 feishu 平台没设 allow_from 的 project"
    if args.projects:
        targets = []
        for name in args.projects:
            if name not in blocks:
                raise SystemExit(f"❌ 配置里没有 project {name!r};现有: {', '.join(n for n in blocks if n)}")
            if platform_of(doc, name) is None:
                raise SystemExit(f"❌ {name!r} 没有 feishu 平台,白名单对它没有意义")
            targets.append(name)
    else:
        targets = []
        for proj in doc.get("projects", []):
            name = proj.get("name") or ""
            plat = platform_of(doc, name)
            if plat is None:
                continue
            if ((plat.get("options") or {}).get("allow_from") or "").strip() and not args.force:
                continue
            targets.append(name)

    print(f"配置文件: {cfg}")
    print(f"会话目录: {data_dir}")
    print(f"显式 ID: {explicit or '(未指定,逐个自动发现)'}")
    print(f"目标 project({len(targets)} 个): {', '.join(targets) if targets else '(无)'}")
    print()

    if not targets:
        print("✅ 没有需要回填的 project"
              "(已有白名单的会跳过;要覆盖它们加 --force,要指定名字就直接写在参数里)")
        return 0

    plans, missing, ambiguous = [], [], []
    for name in targets:
        plat = platform_of(doc, name)
        old = ((plat.get("options") or {}).get("allow_from") or "").strip()
        if explicit:
            plans.append({"name": name, "uid": explicit, "key": "(显式指定)", "old": old})
            print(f"  ▸ {name:<12} → {explicit[:14]}…  (显式指定)")
            continue
        owners = discover_owners(data_dir, name)
        if not owners:
            missing.append(name)
            continue
        uid, key, _ = owners[0]
        if len(owners) > 1:
            ambiguous.append((name, len(owners)))
        plans.append({"name": name, "uid": uid, "key": key, "old": old})
        note = f"  ⚠️ 将覆盖现有白名单 {old[:12]}…" if old else ""
        print(f"  ▸ {name:<12} → {uid[:14]}…  来自会话键 {key[:44]}{note}")
    for name in missing:
        print(f"  ✗ {name:<12} → 没发现会话:先在飞书给它发一条消息,再重跑本脚本")
    for name, count in ambiguous:
        print(f"  ⚠️ {name}: 会话里有 {count} 个不同的用户 ID,这里只写进第一个;"
              f"要换人用 --id 指定,要多人就手工用逗号拼")
    print()

    if missing:
        print(f"  ℹ️ {len(missing)} 个 project 没有会话可用 —— 会话键在机器人**收到过消息**之后才存在。")
    if not plans:
        raise SystemExit(f"❌ 没有任何可回填的目标(有 {len(missing)} 个缺会话)")
    if not args.apply:
        print("巡检模式:未写盘。确认上面的 ID 无误后加 --apply(建议再加 --restart)")
        return 0
    print()

    # 倒序改:插入新行会让**后面**的区块行号偏移,从后往前处理就不必重算区间
    new_lines = list(lines)
    for plan in sorted(plans, key=lambda p: blocks[p["name"]]["start"], reverse=True):
        block = blocks[plan["name"]]
        set_key_in_table(new_lines, block, "[projects.platforms.options]", "allow_from", plan["uid"])
        set_key_at_project_level(new_lines, block, "admin_from", plan["uid"])

    new_text = "\n".join(new_lines) + "\n"
    doc2 = toml_load(new_text)
    if doc2 is None:
        raise SystemExit("❌ 回验失败:改写后不再是合法 TOML,未写盘")

    bad = 0
    for plan in plans:
        plat = platform_of(doc2, plan["name"])
        got = ((plat or {}).get("options") or {}).get("allow_from", "")
        proj = next((p for p in doc2["projects"] if p.get("name") == plan["name"]), {})
        admin = (proj.get("admin_from") or "").strip()
        if got != plan["uid"] or admin != plan["uid"]:
            print(f"  ❌ {plan['name']}: allow_from={got!r} admin_from={admin!r},期望均为 {plan['uid']!r}")
            bad += 1
    if bad:
        raise SystemExit("❌ 回验失败,未写盘(现有配置一字未动)")
    print(f"  ✅ TOML 回验通过:{len(plans)} 个 project 的 allow_from 与 admin_from 都已写入新 App 的 ID")

    backup = cfg.with_suffix(cfg.suffix + ".pre-allow")
    write_text_atomic_lines(backup, text)
    write_text_atomic_lines(cfg, new_text)
    try:
        cfg.chmod(0o600)    # 含密钥,保持创建时的收紧权限
    except OSError:
        pass
    print(f"\n  ✅ 已写入 {cfg}")
    print(f"     备份: {backup}")

    print()
    if cc_running():
        if args.restart:
            try:
                subprocess.run(["pkill", "-f", PROC_MATCH], check=False)
                print("  🔄 已重启 cc-connect(watchdog 会在 10 秒内自动拉起)")
            except (FileNotFoundError, OSError):
                print(f"  ⚠️ 找不到 pkill,请手工重启: pkill -f {PROC_MATCH!r}")
        else:
            print(f"  ⚠️ 配置改动需重启才生效: pkill -f {PROC_MATCH!r}")
    else:
        print("  ℹ️ cc-connect 当前未在运行,下次启动时生效")
    print()
    print("  ℹ️ 群里有多个人时,allow_from 只会写进这次发现到的那一个 ID;要允许多人,"
          "手工把 ID 用逗号拼在同一个 allow_from 里。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
