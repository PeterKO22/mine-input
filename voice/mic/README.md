# voice/mic — 可复用 PTT 语音模块（W2 PoC 核心抽取，W7 macos 集成用）

W2 的 `voice/poc/asr_poc.py` 管线核心（Silero VAD → SenseVoiceSmall(int8) →
CT-Transformer(int8) 标点 → hotwords.txt 热词）抽为可复用模块，供 Squirrel-dev
输入法（macos/w7）与常驻守护进程调用。**`voice/poc/` 既有物未改动**。

## 文件

| 文件 | 作用 |
|---|---|
| `pipeline.py` | `AsrPipeline`：内存 PCM(16k mono f32) → 转写（含低置信启发式）；模型加载一次常驻 |
| `ptt_daemon.py` | 常驻守护进程：JSON-line(stdin/stdout) 协议；PCM16 走 base64（**音频不落盘**） |
| `ptt_client.py` | daemon 的 Python 客户端（与 Swift `W7PttController` 同协议，测试/工具用） |
| `replay_test.py` | W7 (a) 采集→管线脚本化回放验证（17 项断言，见 `build/logs/w7-replay-test.log`） |

## 用法

```bash
# 回放验证（W7 验收 (a) 自动化部分）
bash build/w7-replay-test.sh        # = voice/.venv/bin/python voice/mic/replay_test.py

# 作为模块用
voice/.venv/bin/python -c "
from voice.mic.pipeline import AsrPipeline
import wave, numpy as np
p = AsrPipeline()                    # 模型常驻；默认热词表 voice/poc/hotwords.txt（只读）
raw = wave.open('voice/audio/s1.wav','rb').readframes(10**9)
r = p.transcribe(np.frombuffer(raw, dtype=np.int16).astype(np.float32)/32768.0)
print(r['text'], r['low_confidence'], r['pipeline_ms'])"

# 手动起 daemon（JSON line 协议）
voice/.venv/bin/python voice/mic/ptt_daemon.py
```

## 协议（JSON line，一问一答严格按序）

```
→ {"id":1,"cmd":"ping"}                      ← {"id":1,"ok":true,"ready":false}
→ {"id":2,"cmd":"warmup"}                    ← {"id":2,"ok":true,"load_ms":{...},"hotwords":8}
→ {"id":3,"cmd":"transcribe","sample_rate":16000,"pcm16_b64":"...","hotwords":"(可选覆盖)"}
← {"id":3,"ok":true,"text":"…","low_confidence":false,"confidence":0.9,"reason":"ok",
   "elapsed_ms":231.5,"num_segments":1,"vad_ms":…,"asr_ms":…,"punct_ms":…,"hotword_ms":…}
→ {"id":4,"cmd":"quit"}                      ← {"id":4,"ok":true,"quit":true}
```

## 低置信启发式（不瞎猜，提示重说）

SenseVoice int8 无校准后验置信度，`confidence` 为汉字密度参考值（4.5 字/秒基准）；
判定 `low_confidence=true` 的条件（`pipeline.py`）：VAD 无语音段 / 转写为空 /
无汉字 / 汉字密度 < 0.25 字每秒。上屏方（Swift 侧）见 `low_confidence` 即提示重说，
不 commit。

## 环境

- 模型：`voice/models/`（W2 报告 §3 的下载/校验命令），可用 `MINE_VOICE_MODEL_DIR` 覆盖；
- Python：`voice/.venv`（sherpa-onnx 2.0.1 + numpy + pypinyin，W2 同套）；
- 热词：默认 `voice/poc/hotwords.txt`（只读复用），`MINE_HOTWORDS` 或 API 参数覆盖。
