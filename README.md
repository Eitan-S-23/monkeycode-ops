# monkeycode-ops

MonkeyCode 容器(跑 cc-connect + codex/claude 两个飞书机器人 + CPA 代理,
可选再跑一个 mihomo/Clash 代理)的部署与恢复脚本集。

**这个仓库存在的唯一理由**:那个容器**没有任何开机自启机制**,平台也不会在重启后
替你拉起任何进程(依据见 `restore-all.sh` 头部,逐条列了平台源码里的查证位置)。
`/workspace` 里的文件会留下,但进程一个都不会回来。而本机到容器**没有直达的 shell
通道**,真出事时几十 KB 的脚本根本送不进去。

所以:脚本放在这里,容器出事时一条命令拉下来。

## 容器重建后的恢复流程

**第 1 步 · 在容器里铺脚本**(一条命令):

```bash
curl -fsSL https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/bootstrap.sh | bash
```

它会判台(认错机器会直接停)、把脚本铺进 `/workspace/cc-connect/`,并在最后
列出**还缺什么**。

**第 2 步 · 把两个密钥文件送进去**:

`bootstrap.sh` 铺不了这两个 —— 它们是密钥,不在仓库里(原因见下一节)。
`/workspace/cc-connect/bots.env` 和 `/workspace/cc-connect/providers.toml`
就位后继续。

**第 3 步 · 拉起服务**:

```bash
bash /workspace/cc-connect/restore-all.sh
```

幂等,已经在跑的服务会跳过。跑完自己打汇总表。

## Clash 代理(可选,但要手工投递一次订阅)

容器里没有"系统代理"这一层 —— 装上 mihomo **不等于**谁自动走代理。要让哪个程序
走,先 `source /workspace/clash/proxy.env` 再跑它。这也是它跟另外几样服务最大的
区别:那些是"给容器用的",这个是"给你在那个 shell 里手动用的"。

订阅(`config.yaml`)含节点密钥,和 `bots.env` 一样**不进仓库、也备份不了**,
所以脚本只能替你把内核拉起来,装不了订阅:

```bash
# 1. 把本机订阅 YAML 投递成 /workspace/clash/config.yaml
#    控制台自带文件管理器:开发环境 → 文件(/console/files?envid=...&path=/workspace/clash)
#    直接传 config.yaml 即可,10MB 以内都行;没有界面时用 make-upload-cmd.sh
#    生成 base64 一行命令,粘进 web 终端(生成物含节点密钥,别贴进聊天)
# 2. 拉起内核(首次自动下内核二进制与规则库,约 35MB;之后跳过)
bash /workspace/cc-connect/clash-install.sh
```

之后 `restore-all.sh` 的 `[5/6]` 段每次都会带上它:已经在跑就跳过,没跑就调上面
这个脚本。没投递订阅时那一段打印一行"跳过",**不影响**其它服务恢复。

### 让 codex / claude 跟着分流走(`set-agent-proxy.py`)

上面那步只是把 mihomo 拉起来,**不会**有谁自动走它 —— 容器里没有"系统代理"这一层。
要让 cc-connect 里跑的两个 agent 走,得把代理地址注入给它们:

```bash
python3 /workspace/cc-connect/set-agent-proxy.py     # 只读巡检,看当前挂没挂
python3 /workspace/cc-connect/set-agent-proxy.py --on --restart
python3 /workspace/cc-connect/set-agent-proxy.py --off
```

它改的是 `config.toml` 里每个 codex / claudecode project 的
`[projects.agent.options.env]` 子表 —— cc-connect 支持按 project 注入环境变量,这两个
agent 都读它(agent/claudecode/claudecode.go:226、agent/codex/codex.go:77)。注入
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` 四个键,幂等,改写前先用
TOML 解析器回验,解析不过绝不落盘。

挂上之后的行为**不是**"所有流量都走节点":两个 CLI 的出站先交给 mihomo,由订阅里
那 1335 条规则逐条判 —— 命中 `GEOIP,CN,DIRECT` 的直连,其余走节点,省的是节点流量。
但"先交给 mihomo"这一步是全部:判成直连的也照样经过它,所以 mihomo 不在时它们会
**全断,不会自动退回直连**。

两条容易忽略的细节:

- `NO_PROXY` 里必须含 `127.0.0.1` —— codex 的 app server 连的是
  `ws://127.0.0.1:3845`(agent/codex/codex.go:123),本机连接走代理会直接连不上。
- **只给这两个 agent 挂,不挂 cc-connect 自己**。另一条更省事的路是往 `run.sh` 里
  `source proxy.env`,但那会把 cc-connect 的飞书长连接也推进 mihomo:mihomo 一挂,
  机器人连消息都收不到,你只能去网页终端看现场。现在这样至少还收得到一句"我出站
  全失败了"。

⚠️ **重新跑 `deploy-codex.sh` 会重写 `config.toml`,写进去的 env 段会一起没掉**,
需要重跑一次本脚本。`restore-all.sh` 不重写 `config.toml`,所以容器重启不受影响。

## 扩容:再挂 9 个 codex 机器人(`add-codex-bots.py` + `set-allow-from.py`)

场景:手里又多了 9 个飞书 App,要作为 9 个 `codex1`…`codex9` project 挂进同一个
cc-connect,agent 配置与现有的 `codex` project 完全一致。

**为什么要脚本而不是手抄**:provider、`sandbox_mode`、模型别名、`env` 这些抄错一处,
只会以"某个机器人行为不对"的形式暴露;而一个飞书 App 的长连接只能挂一个 project,
App ID 与 Secret 也不能串台。所以 `add-codex-bots.py` 是**整块复制**现有 `codex`
project 的正文,只改必须改的键,并在落盘前用 TOML 解析器把新 project 与源 project
**逐路径比对** —— 差异超出下面这四条就直接报错、不落盘。

有意与源 project 不同的四处(脚本每次运行都会打印,不藏在日志里):

| 改动 | 为什么 |
|---|---|
| `name` → `codex<N>` | cc-connect 按 name 认 project |
| `codex_home` → `/workspace/codex-home<N>` | 9 个机器人共用一份会让多进程并发改同一个 `auth.json`(每次会话启动都写),写坏了表现为"某个机器人起不来";`/sessions` 还会互相看到对方的会话 |
| `app_id` / `app_secret` | 每个机器人一个 App;一个 App 的长连接只能挂一个 project |
| 丢弃 `admin_from` / `allow_from` / `heartbeat` | 前两者是**按 App 隔离的 open_id**(新 App 里同一个人的 `ou_xxx` 不同),照抄的结果是你的消息被静默忽略、且不报任何错;`heartbeat` 的 `session_key` 里带着旧机器人的会话,照抄等于 9 个机器人的心跳全推进同一个旧会话 |

三步(前两步在本机,其余在容器里):

```bash
# 1. 本机:按 secret.txt 生成 bots9.env(含真实密钥,别贴进聊天)
python make-bots9-env.py

# 2. 本机:投递进容器 —— 生成一条 base64 命令,粘进 web 终端
bash make-upload-cmd.sh bots9.env

# 3. 容器:先看它打算做什么,再落盘
python3 add-codex-bots.py bots9.env --dry-run
python3 add-codex-bots.py bots9.env --restart
```

脚本本体也从仓库取(容器里一行,纯 ASCII):

```
curl -fsSL https://raw.githubusercontent.com/Eitan-S-23/monkeycode-ops/main/add-codex-bots.py -o /workspace/cc-connect/add-codex-bots.py
```

**重启之后还有两步**(脚本收尾时也会打印):

```bash
# 4. 先逐个给 9 个机器人发一条消息 —— 没收到过消息的机器人在 cc-connect 里没有会话;
#    白名单要从会话键里反查你的 open_id,没会话就查不到
python3 set-allow-from.py                 # 巡检:只列出发现到的 ID,不改配置
python3 set-allow-from.py --apply --restart

# 5. 可选:配心跳(session_key 自动发现),逐个来
python3 set-heartbeat.py codex1 --restart
```

`set-allow-from.py` 的 `open_id` 是从会话快照 `${data_dir}/sessions/codex<N>_*.json`
里的会话键(`feishu:<chatID>:<userID>`)反查的,不自造也不人工抄;空的 `allow_from`
在 cc-connect 里等于不设限,谁都能用,所以这一步别省。群里有多个人时它只写进第一个
ID,要允许多人手工用逗号拼。

**换 App secret / 重新分配机器人**:改完 `bots9.env` 重跑 `--update`,只会就地替换已存在
project 的 `app_id` / `app_secret`,其余键一字不动。已存在的 project 默认跳过;要强制
换白名单用 `set-allow-from.py --force`。

改动前的备份落在 `config.toml.pre-bots` 与 `config.toml.pre-allow`,改坏了可以直接还原。

## 密钥从哪来(为什么仓库里没有)

**仓库零密钥,而且不需要备份密钥就能重建** —— 因为密钥文件都是**本机生成**的:

| 文件 | 生成方式 | 输入源 |
|---|---|---|
| `providers.toml` | `python export-local-providers.py` | 本机 `~/.cc-connect/config.toml` |
| `bots.env` | `python make-bots-env.py` | 本机 `secret.txt` + 上一步的 `providers.toml` |
| `bots9.env` | `python make-bots9-env.py` | 本机 `secret.txt`(9 个 codex 机器人那几段) |

输入源(`~/.cc-connect/config.toml` 和 `secret.txt`)都只在本机,**都不进这个
仓库**。只要本机还在,这些文件随时能重新生成;真丢了也该先救那两样,而不是救
这个仓库。

**顺序不能反**:`make-bots-env.py` 要读 `providers.toml`,所以先导出 providers。
`make-bots9-env.py` 只吃 `secret.txt`,与 providers 无关,随时可跑。

生成出来的文件请当密钥文件对待 —— 别提交进仓库、别贴进聊天。
`.verify-nosecrets.sh` 会把这三个文件里的真值逐个拿去搜已跟踪文件,推之前跑一遍。

## 文件清单

**恢复与部署**(在容器里跑)
- `restore-all.sh` — 容器重启后一键恢复,幂等;先跑这个
- `clash-install.sh` — 装/起 mihomo(Clash.Meta)内核,幂等;由 `restore-all.sh`
  的 `[5/6]` 段调用。**它只装内核,装不了订阅** —— 订阅含节点密钥,只能手工投递
- `deploy-cc-connect.sh` / `deploy-codex.sh` / `deploy-cpa-tunnel.sh` — 首次部署
- `rollback-cc-connect.sh` — 回滚

**配置生成**(在本机跑)
- `export-local-providers.py` — 从本机 cc-connect 配置导出 provider 段
- `make-bots-env.py` — 按 `secret.txt` + `providers.toml` 生成 `bots.env`
- `make-bots9-env.py` — 按 `secret.txt` 生成 `bots9.env`(9 个 codex 机器人的凭证;
  段名只认 `monkey-codex<序号>`,混进别的段会报错而不是静默少部署)

**配置合并**(在容器里跑)
- `apply-providers.py` — 把导出的 provider 段并进容器的 `config.toml`
- `set-heartbeat.py` — 配心跳;session_key 自动发现(扫快照文件里所有像
  `平台:会话:用户` 的字符串,不赌它落在哪个字段)
- `set-agent-proxy.py` — 给 codex / claude 两个 agent 注入 Clash 代理(上一条的
  下一层,做法见「让 codex / claude 跟着分流走」)
- `add-codex-bots.py` — 把现有 `codex` project 整块复制成 9 个机器人 project
  (见「扩容:再挂 9 个 codex 机器人」)
- `set-allow-from.py` — 从会话快照反查 open_id,回填 `allow_from` / `admin_from`

**命令生成**(在本机跑,专为过飞书)
- `make-skill-cmd.sh` / `make-fallback-cmd.py` / `make-upload-cmd.sh` /
  `make-whitelist-cmd.sh` / `b64cmd.sh`
- 生成的命令一律**纯 ASCII 无引号的一整行** —— 中文和 emoji 过飞书会变
  U+FFFD,直引号会变弯引号,长命令会被截断

**skill 源**
- `skills/feishu-send/SKILL.md` — `make-skill-cmd.sh` 读它生成安装命令

**本地验证**(在本机跑)
- `.verify-*.sh` / `.verify-*.py` — 每个都对着真实 CLI 或 cc-connect 源码比对,
  不是对着自己的假设比对
- `.verify-bots9.sh` — 用仿造的 `config.toml` 与假会话目录跑通扩容那三个脚本:
  断言新 project 与源 project 的差异**只有**声明的那几处、`allow_from` 落在
  `platforms.options` 而 `admin_from` 落在 `projects` 层、原有 project 的字节一字未动

## 本机验证依赖

`.verify-models-heartbeat.sh` 和 `.verify-skill.sh` 要拿 cc-connect 上游源码做
实现比对。那份克隆**不进仓库**(20MB 且可重建),本机缺了就补一个:

```bash
git clone --depth 1 <cc-connect 上游地址> .cache/cc-connect-src
```

## 别搞混:本机还有另一台容器

本机运维着**两台互不相通的容器**。这一台是 MonkeyCode(`/workspace/cc-connect`
`/workspace/cpa`);另一台是腾讯 Cloud Studio `icgsqq`,跑 new-api,标志路径是
`/workspace/run-new-api.sh`、`/workspace/pylibs`,本机项目在 `cloudstudio-keepalive`。

两边的操作通道和代价完全不同 —— 拿另一台的 Worker 通道打这台,会**正常返回
HTTP 200** 但命令落在错误的机器上,还白烧当天的浏览器额度。

分不清时读 `container-map` skill;那一台的细节在 `cloudstudio-ops` skill。
