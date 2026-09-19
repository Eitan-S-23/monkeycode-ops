# 生成两样东西:
#   ① 诊断命令:一次问清 skill 到底装上没有、codex 本体认不认、版本够不够
#   ② 兜底命令:把一段说明追加进 <CODEX_HOME>/AGENTS.md 与 $HOME/.claude/CLAUDE.md
#      —— 这两个文件是 agent 每次启动都会读的"记忆文件",不依赖 skill 触发机制
import gzip, base64, pathlib

BLOCK = """<!-- feishu-send:begin 由 cc-connect 运维脚本写入,勿手改,整块可删 -->
## 发文件给用户:用 cc-connect send

用户通过飞书跟你对话,你在容器里跑。要把文件/图片/语音/视频送到用户眼前,只有一条路:

    cc-connect send --file /绝对/路径 -m "一句话说明这是什么"

这就够了:不需要 -p、不需要 -s、不需要 --data-dir。cc-connect 拉起你这个会话时,
已经把 CC_PROJECT / CC_SESSION_KEY / CC_DATA_DIR 注入你的进程环境,并把 cc-connect
这个可执行文件加进了 PATH。所以不带寻址参数 = 发回当前对话 = 发到用户眼前。

    --file  通用附件         --image  图片(直接显示在消息里)
    --audio 语音气泡         --video  视频播放器        --tts  把文本合成语音
    路径必须写绝对路径(你可能是从任意目录启动的)。

输出 Message sent successfully. 只说明本机 daemon 收下了请求;真失败会打印 Error: 并以退出码 1 结束。

不要去调飞书 HTTP 接口(tenant_access_token、/im/v1/files),凭据在 daemon 手里,你手上没有也不需要。
更不要因为"我没有网络访问权限 / 没有飞书凭据 / 没有飞书接口"就断定发不出去 —— 这三样一样都不需要,
cc-connect send 全程走本地 socket。用户问"你能不能发文件""为什么没收到"时,答案也是这条命令。
<!-- feishu-send:end -->
"""
b64 = base64.b64encode(gzip.compress(BLOCK.encode("utf-8"), 9)).decode("ascii")

H = '${HOME:-/root}'
TMP = "/tmp/fsblk.md"

diag = (
    "echo ==1HOME== ; echo HOME=$HOME ; "
    "echo ==2skills== ; ls -l $HOME/.claude/skills/feishu-send/SKILL.md /workspace/codex-home/skills/feishu-send/SKILL.md $HOME/.codex/skills/feishu-send/SKILL.md ; "
    "echo ==3md5== ; md5sum $HOME/.claude/skills/feishu-send/SKILL.md /workspace/codex-home/skills/feishu-send/SKILL.md $HOME/.codex/skills/feishu-send/SKILL.md ; "
    "echo ==4vers== ; /workspace/npm-global/bin/codex --version ; /workspace/npm-global/bin/claude --version ; "
    "echo ==5codexread== ; CODEX_HOME=/workspace/codex-home /workspace/npm-global/bin/codex debug prompt-input hi > /tmp/pi.txt 2>/tmp/pi.err ; "
    "echo rc=$? ; echo bytes=$(wc -c < /tmp/pi.txt) ; echo hits=$(grep -c feishu-send /tmp/pi.txt) ; "
    "echo --err-- ; head -c 400 /tmp/pi.err ; "
    "echo ==6memfiles== ; ls -l /workspace/codex-home/AGENTS.md $HOME/.claude/CLAUDE.md ; "
    "rm -f /tmp/pi.txt /tmp/pi.err"
)

fb = (
    "echo " + b64 + " | base64 -d | gunzip > " + TMP + " ; "
    "mkdir -p " + H + "/.claude /workspace/codex-home ; "
    "grep -q feishu-send:begin " + H + "/.claude/CLAUDE.md 2>/dev/null || cat " + TMP + " >> " + H + "/.claude/CLAUDE.md ; "
    "grep -q feishu-send:begin /workspace/codex-home/AGENTS.md 2>/dev/null || cat " + TMP + " >> /workspace/codex-home/AGENTS.md ; "
    "rm -f " + TMP + " ; "
    "echo ==claude== ; grep -c feishu-send:begin " + H + "/.claude/CLAUDE.md ; "
    "echo ==codex== ; grep -c feishu-send:begin /workspace/codex-home/AGENTS.md ; "
    "echo ==size== ; wc -c " + H + "/.claude/CLAUDE.md /workspace/codex-home/AGENTS.md"
)

out = pathlib.Path(".gen-fallback.out")
out.write_text(diag + "\n@@@\n" + fb + "\n", encoding="utf-8")
print("diag chars :", len(diag))
print("fallback   :", len(fb))
print("block bytes:", len(BLOCK.encode('utf-8')))
for n, c in (("diag", diag), ("fallback", fb)):
    bad = [ch for ch in c if ord(ch) < 32 or ord(ch) > 126]
    print(f"{n:9s} 纯ASCII={not bad} 含引号={('\"' in c) or (chr(39) in c)}")
