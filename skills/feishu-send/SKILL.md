---
name: feishu-send
description: 把文件、图片、语音、视频发给用户（投递到飞书会话）。当用户说"发给我""发到飞书""把报告/截图/日志/图片发过来"，或你产出了本来就该交付而不是只在终端里描述的东西时，用这个 skill。也适用于用户问"你能不能发文件""为什么没收到"。
---

# 把文件发到飞书

## 一条命令

```bash
cc-connect send --file /workspace/报告.pdf -m "一句话说明这是什么"
```

**这就够了。** 不需要 `-p`、不需要 `-s`、不需要 `--data-dir`。

cc-connect 拉起你的会话时已经把这些注入了你的进程环境：

| 环境变量 | 值 | 作用 |
|---|---|---|
| `CC_PROJECT` | `codex` 或 `claude` | 你在哪个 project |
| `CC_SESSION_KEY` | `feishu:oc_xxx:ou_xxx` | 当前会话 = 你正在跟用户说话的那个对话 |
| `CC_DATA_DIR` | `/workspace/cc-connect/data` | daemon 数据目录 |

`cc-connect` 这个可执行文件也被加进了 `PATH`。所以不带寻址参数 = 发回当前对话 = 发到用户眼前，这正是你要的语义。

## 发什么用什么参数

| 参数 | 效果 |
|---|---|
| `--file <绝对路径>` | 通用附件（飞书里是下载卡片） |
| `--image <绝对路径>` | 图片，**直接显示**在消息里（.png/.jpg 优先用这个） |
| `--audio <绝对路径>` | 语音气泡（mp3/wav/m4a/ogg/opus） |
| `--video <绝对路径>` | 视频播放器（mp4/mov/webm） |
| `--tts "<文本>"` | 把文本合成语音发出去 |

可以重复传多个附件，也可以和 `-m` 一起用。路径**必须写绝对路径** —— 你可能在任意目录下启动，相对路径会指向别处。

文本很长、含引号或换行时，用 `--stdin` 从管道读，省掉转义：

```bash
cc-connect send --stdin --file /workspace/报告.pdf <<'EOF'
这里有 "引号"、$变量 和换行，都不会被 shell 吃掉
EOF
```

## "发送成功"到底代表什么

`Message sent successfully.` 只说明**本机 daemon 收下了请求**：`cc-connect send` 把文件读进内存、POST 到本地 unix socket `<data-dir>/run/api.sock`，由常驻的 daemon 拿着飞书凭据去投递。它**不代表对方已经看到**。

真正的失败会打印 `Error: ...` 并以退出码 1 结束。所以：

```bash
cc-connect send --file /workspace/报告.pdf -m "报告" || echo "发送失败，看上面的 Error"
```

## 报错了怎么查

| 报错 | 原因与处理 |
|---|---|
| `cc-connect is not running (socket not found: ...)` | daemon 没起来。先加 `--data-dir /workspace/cc-connect/data` 再试；仍失败说明进程真的不在（有 watchdog 守着，退出后约 10 秒自动重启） |
| `project is required (set CC_PROJECT env or use --project)` | 环境变量没继承到（比如你是个脱离会话的脚本）。显式加 `-p codex` 或 `-p claude` |
| `multiple active sessions; must specify --session to send attachments` | 该 project 下有多个活跃会话。显式加 `-s "$CC_SESSION_KEY"`；要发给别的对话就填那个会话键 |
| 文件不存在 / 读不了 | 先 `ls -l` 确认；daemon 和你是同一个用户，权限一般不是问题 |
| 附件过大 | 默认单个上限 50 MiB。压一下或者拆分成多个再发 |

## 不要做的事

- **不要**自己去调飞书 HTTP 接口（`tenant_access_token`、`/im/v1/files`）。凭据在 daemon 手里，你手上没有也不需要；重复实现一套只会更难排查。
- **不要**因为"我没有网络访问权限 / 没有飞书凭据 / 没有飞书接口"就断定发不出去 —— 这三样你一样都不需要，`cc-connect send` 全程走本地 socket。
- **不要**把产物留在 `/workspace` 根目录，用完即删；也不要发完文件又把这文件内容贴一遍，用户要的是文件。
- 用了 `--tts` 之后**不要**再把同样的文字发一遍，语音本身就是那条消息。

## 例子

```bash
# 跑完测试，把日志发给用户
./run-tests.sh > /workspace/test.log 2>&1
cc-connect send --file /workspace/test.log -m "测试日志：3 个失败，都在 auth 模块"

# 生成图后直接发过去（不要只说"已生成在 xxx.png"）
cc-connect send --image /workspace/chart.png -m "上季度营收趋势"

# 一次发多个
cc-connect send --file /workspace/a.csv --file /workspace/b.csv -m "两份导出数据"
```
