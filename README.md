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

## 密钥从哪来(为什么仓库里没有)

**仓库零密钥,而且不需要备份密钥就能重建** —— 因为两个密钥文件都是**本机生成**的:

| 文件 | 生成方式 | 输入源 |
|---|---|---|
| `providers.toml` | `python export-local-providers.py` | 本机 `~/.cc-connect/config.toml` |
| `bots.env` | `python make-bots-env.py` | 本机 `secret.txt` + 上一步的 `providers.toml` |

两个输入源(`~/.cc-connect/config.toml` 和 `secret.txt`)都只在本机,**都不进这个
仓库**。只要本机还在,这两个文件随时能重新生成;真丢了也该先救那两样,而不是救
这个仓库。

**顺序不能反**:`make-bots-env.py` 要读 `providers.toml`,所以先导出 providers。

生成出来的两个文件请当密钥文件对待 —— 别提交进仓库、别贴进聊天。

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

**配置合并**(在容器里跑)
- `apply-providers.py` — 把导出的 provider 段并进容器的 `config.toml`
- `set-heartbeat.py` — 配心跳;session_key 自动发现(扫快照文件里所有像
  `平台:会话:用户` 的字符串,不赌它落在哪个字段)
- `set-agent-proxy.py` — 给 codex / claude 两个 agent 注入 Clash 代理(上一条的
  下一层,做法见「让 codex / claude 跟着分流走」)

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
