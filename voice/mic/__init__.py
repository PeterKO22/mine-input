# voice.mic — W2 PoC 核心抽取出的可复用语音采集/转写模块（W7 macos 集成用）
#
# 组成：
#   pipeline.py   — AsrPipeline：VAD→SenseVoice→标点→热词 全离线管线（含低置信启发式）
#   ptt_daemon.py — 常驻守护进程：JSON-line(stdin/stdout) 协议，模型常驻，PCM 内存传递
#   ptt_client.py — daemon 的 Python 客户端（测试 / 降级小工具用；Swift 侧同协议）
#   replay_test.py— 采集→管线脚本化回放验证（W7 验收 (a) 的自动化部分）
#
# 约束（W7 任务）：音频只走内存（环形缓冲 → base64 JSON → 管线 numpy 数组），不落盘。
# 不改动 voice/poc/ 既有物；热词默认复用 voice/poc/hotwords.txt（只读）。
from .pipeline import AsrPipeline  # noqa: F401
