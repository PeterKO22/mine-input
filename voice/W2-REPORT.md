# W2 voice — 语音管线离线 PoC 报告

对应里程碑 **M2**：离线 ASR PoC——WAV→转写（带标点/热词），实测延迟。
对应规格：`docs/开发任务计划.md` W2 车道；`docs/技术方案-v0.4.md` §6 管线；
`docs/需求文档-v1.0.md` FR2 / NFR2 / NFR4 / NFR5。

## 1. 结论摘要

- **管线跑通（全离线）**：WAV(16k mono) → Silero VAD 流式切段 → SenseVoiceSmall(int8) 转写 → CT-Transformer(int8) 标点 → 热词后处理（显式别名 + 同音纠偏），代码在 `voice/poc/asr_poc.py`。
- **转写正确率主观可用**：`say -v Tingting` 生成的 5 句中文样音逐句转写与原文**逐字一致**（含标点）；唯一错误是借词同音混淆「可颂→可送」，被热词后处理纠正（见 §5）。
- **延迟**：模型常驻后，27.6s 音频全管线 **490ms**（RTF 0.018）；单段 ASR 47–121ms。以「松开→全管线出结果」代理 NFR2：**0.38–0.49s ≪ 1.5s**，达标（见 §6）。
- **模型清单**：3 个模型全部记录下载源/体积/量化档/SHA256（见 §3）。大模型放 `voice/models/`，**不进 git**（`voice/.gitignore` 已注明，§3 给出重新获取命令）。
- **无硬性 blocker**；遗留项见 §8。

## 2. 环境与装配

| 项 | 值 |
|---|---|
| 机器 | macOS 27.0.1，Apple M5 Max，18 核（6P+12E），128GB |
| Python | `python3 -m venv voice/.venv`（venv 隔离，未动系统环境） |
| 关键依赖 | sherpa-onnx **2.0.1**（pip wheel，自带 macOS arm64 onnxruntime 二进制）、numpy 2.0.2、pypinyin（同音纠偏用） |
| TTS 样音 | macOS 自带 `say -v Tingting`（zh_CN，本机可用） |

装配命令（可复现）：

```bash
cd /Users/you/AITECreate/mine-input
python3 -m venv voice/.venv
PIP_USER=0 voice/.venv/bin/python -m pip install sherpa-onnx numpy pypinyin
```

> **坑**：本机 `/etc/pip.conf` 全局设了 `user = true`，venv 内 pip 会报
> `Can not perform a '--user' install`；用 `PIP_USER=0` 前缀绕过（不是网络或权限问题）。

## 3. 模型清单（下载源 / 体积 / 量化档）

| 模型 | 用途 | 下载源 | 压缩包体积 | 解压后关键文件 | 量化档 |
|---|---|---|---|---|---|
| SenseVoiceSmall | ASR 转写 | GitHub `k2-fsa/sherpa-onnx` Releases tag `asr-models`，asset `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2` | 163,002,883 B（155.4 MiB） | `model.int8.onnx` 239,233,841 B（228 MiB）+ `tokens.txt` 315,894 B | **int8** |
| Silero VAD (v4) | 语音活动检测切段 | 同上 tag，asset `silero_vad.onnx` | 643,854 B（629 KiB，单文件） | 同左 | fp32（官方另有 `silero_vad.int8.onnx` 212,860 B 可选） |
| CT-Transformer | 标点恢复 | GitHub Releases tag `punctuation-models`，asset `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2` | 64,717,756 B（61.7 MiB） | `model.int8.onnx` 75,519,198 B（72 MiB）+ `tokens.json` 4,207,480 B | **int8** |

SHA256（下载后校验）：

```
7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e  sense-voice-int8.tar.bz2
9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6  silero_vad.onnx
c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1  punct-ct-transformer-int8.tar.bz2
```

**下载源实测记录**（任务预案 HF→hf-mirror 的链路在本机均不可用）：

- `huggingface.co` 直连：API 与 `resolve` 下载均返回 **HTTP 401**（网络层拦截，非模型私有）；
- `hf-mirror.com`：API 308 跳转回 `huggingface.co`（随后 401），`resolve` 路径 SSL 握手失败/401 —— **hf-mirror 同样不可用**；
- 最终全部走 **GitHub Releases 直连**（`github.com/.../releases/download/...`，本机畅通）。

**模型获取方式（不进 git，`voice/models/` 由 `.gitignore` 排除）**：

```bash
cd voice/models
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
tar xjf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
tar xjf sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
```

## 4. PoC 代码与管线

| 文件 | 作用 |
|---|---|
| `voice/poc/asr_poc.py` | 主管线：WAV→VAD 切段→SenseVoice 转写→CT-Transformer 标点（含重复标点合并）→热词后处理；逐段打印耗时与转写，结尾输出延迟表 + 热词开/关对比，JSON 落 `voice/poc/last_run.json` |
| `voice/poc/hotwords.txt` | 热词表（格式与机制见下） |
| `voice/poc/gen_audio.sh` | `say -v Tingting --data-format=LEI16@16000 -o` 生成 s1–s5.wav + benchmark.wav（5 句连读）并调用 make_multi.py |
| `voice/poc/make_multi.py` | s1–s5 按 0.8s 换气间隔拼接为 benchmark_multi.wav（VAD 多段基准） |
| `voice/poc/run_*.txt` | 实测运行日志（报告数据来源） |

**hotwords.txt 格式**：每行 `正词 [显式别名1 别名2 ...]`，`#` 注释。两级纠偏（`apply_hotwords`）：

1. **显式别名替换**：别名出现在转写中→直接替换为正词（可含非同音别名）；
2. **同音窗口匹配**：转写中任意与正词同音（pypinyin 无声调拼音）的连续汉字段→替换为正词。

热词**只纠偏不改写**：转写已正确时不产生任何变化（s1/s2/s4/s5 实测「无差异」即为证）。

验证命令：

```bash
# 生成样音（Tingting，16k mono WAV）
bash voice/poc/gen_audio.sh
# 逐句转写 + 热词开/关对比 + 延迟表
voice/.venv/bin/python voice/poc/asr_poc.py 'voice/audio/s*.wav'
# 多段基准（VAD 切 4 段，逐段延迟）
voice/.venv/bin/python voice/poc/asr_poc.py voice/audio/benchmark_multi.wav
# 对照组：关闭热词
voice/.venv/bin/python voice/poc/asr_poc.py voice/audio/s3.wav --no-hotwords
```

## 5. 基准样音与转写全文

样音：`say -v Tingting --data-format=LEI16@16000`（16k/16bit/mono）合成，共 5 句、23.5s；benchmark_multi.wav 27.6s（含 4×0.8s 间隔）。

| # | say 输入原文 | 转写结果（热词开） | 逐句一致 |
|---|---|---|---|
| s1 | 今天天气不错，我们下午去公园散步吧。 | 今天天气不错，我们下午去公园散步吧。 | ✅ |
| s2 | 请帮我打开语音输入功能，按住右上角的命令键就可以了。 | 请帮我打开语音输入功能，按住右上角的命令键就可以了。 | ✅ |
| s3 | 我在星巴克点了一杯拿铁和一个可颂面包。 | 我在星巴克点了一杯拿铁和一个可颂面包。 | ✅（热词修正后） |
| s4 | 请把这份文件发送给张伟和李娜，谢谢。 | 请把这份文件发送给张伟和李娜，谢谢。 | ✅ |
| s5 | 昨天看新闻说，嫦娥探测器又传回了新的月面照片。 | 昨天看新闻说，嫦娥探测器又传回了新的月面照片。 | ✅ |

整段连读转写全文（benchmark_multi.wav，VAD 4 段拼接，热词开）：

> 今天天气不错，我们下午去公园散步吧。请帮我打开语音输入功能，按住右上角的命令键就可以了。我在星巴克点了一杯拿铁和一个可颂面包。请把这份文件发送给张伟和李娜，谢谢。昨天看新闻说，嫦娥探测器又传回了新的月面照片。

与原文逐字一致。另测 5 句无停顿连读（benchmark.wav，单段 23.7s）：文字全对，标点有 2 处与原文出入（「功能，」→「功能。」、「探测器，又」多一逗号），属标点模型边界判断差异，不影响上屏可用性。

## 6. 热词开/关对比（实测）

唯一 ASR 错误为借词同音混淆（s3）：

| 项 | 转写 |
|---|---|
| 热词**关** | 我在星巴克点了一杯拿铁和一个**可送**面包。 |
| 热词**开** | 我在星巴克点了一杯拿铁和一个**可颂**面包。 |
| 触发机制 | 同音替换: 可送→可颂（pypinyin 同音窗口匹配，hotwords.txt 中 `可颂` 词条） |

其余 4 句开/关**无差异**——符合「热词只纠偏、不改写」的设计。hotwords.txt 另备有显式别名（星八克/章伟/李那/常娥等）供真实误识别出现时兜底，本次实测未触发。

## 7. 延迟数据（实测，M5 Max / 4 线程）

模型加载（一次性，之后常驻）：VAD ≈10ms + ASR 358–594ms + 标点 58–112ms，**合计 0.43–0.76s**。

逐句（每文件 1 段；s1 含 pypinyin 首次预热 74ms）：

| 文件 | 音频s | 段数 | VAD ms | ASR ms | 标点 ms | 热词 ms | 总耗时 ms | RTF |
|---|---|---|---|---|---|---|---|---|
| s1.wav | 4.16 | 1 | 11.0 | 49.7 | 1.4 | 74.3 | 136.3 | 0.033 |
| s2.wav | 5.69 | 1 | 13.2 | 94.3 | 3.4 | 3.2 | 114.1 | 0.020 |
| s3.wav | 4.08 | 1 | 10.3 | 47.3 | 2.3 | 2.0 | 62.0 | 0.015 |
| s4.wav | 4.29 | 1 | 10.2 | 49.9 | 2.3 | 1.6 | 64.0 | 0.015 |
| s5.wav | 5.36 | 1 | 13.1 | 63.1 | 2.8 | 2.2 | 81.2 | 0.015 |

多段基准 benchmark_multi.wav（27.58s，VAD 切 4 段；s2+s3 因句间判定合并为一段）：

| 段 | 起点s | 段长s | ASR ms | 转写 |
|---|---|---|---|---|
| 1 | 0.00 | 4.74 | 60.4 | 今天天气不错，我们下午去公园散步吧。 |
| 2 | 4.86 | 11.37 | 120.7 | 请帮我打开语音输入功能，按住右上角的命令键就可以了。我在星巴克点了一杯拿铁和一个可颂面包。 |
| 3 | 16.38 | 4.84 | 65.3 | 请把这份文件发送给张伟和李娜，谢谢。 |
| 4 | 21.37 | 5.93 | 75.4 | 昨天看新闻说，嫦娥探测器又传回了新的月面照片。 |

汇总：VAD 61.7ms + ASR 321.8ms + 标点 11.6ms + 热词 94.9ms = **总耗时 490.0ms，RTF 0.0178**。
另 5 句无停顿连读 benchmark.wav（23.69s 单段）：总耗时 380.0ms，RTF 0.0160。

**NFR 对照**（NFR2/NFR4/NFR5）：

- **NFR2 松开→上屏 ≤1.5s**：以「模型常驻后全管线耗时」代理 → 0.38–0.49s，**达标**（不含麦克风采集与上屏 IO，见 §8）。「滚动 ≤500ms 滞后」代理：逐段 ASR 47–121ms/段，按 VAD 段粒度滚动刷新远低于 500ms。
- **NFR4 全离线**：**达标**——运行全程无网络调用（模型本地加载，转写/标点/热词纯 CPU）。
- **NFR5 资源**：ASR int8 228 MiB + 标点 int8 72 MiB + VAD 0.6 MiB ≈ **300 MiB** 磁盘常驻，符合「百 MB 级」；常驻内存 RSS 未量化（§8）。

## 8. 实现要点（踩坑记录）与遗留项

**踩坑记录**（已解决，写给后续集成）：

1. **`VoiceActivityDetector` 整段喂入丢段**：一次性 `accept_waveform(整条音频)` 只会吐出末尾一小段（sherpa-onnx 2.0.1 实测）；必须按 0.5s 块流式喂入并即时 `front/pop`——这恰好与 PTT 边说边切段的形态一致。
2. **跨文件须 `vad.reset()`**：否则时间轴/残留段串进下一个文件（多文件跑批曾把 s2 切成 s1 的尾巴）。
3. **VAD 触发滞后丢字头**：切段起点晚于真实语音起点（「请把」→「把」）；段边界前后各扩 **0.25s pre-roll** 后逐字恢复。
4. **双标点**：SenseVoice(use_itn) 自带标点，CT-Transformer 再补一次（「吧。，请」）；后处理合并连续标点串（优先保留 。！？）。
5. **`say -o xx.wav` 默认产出 AIFF**，必须加 `--data-format=LEI16@16000` 才是 16k/16bit/mono 真 WAV。
6. venv 内 pip 被系统 `pip.conf` 的 `user=true` 卡死：`PIP_USER=0` 绕过（§2）。

**遗留项**：

1. **HF/hf-mirror 均不可用**（§3），已用 GitHub Releases 替代；若目标环境 GitHub 也受限，需另备镜像。
2. **常驻内存 RSS 未量化**（NFR5 的内存侧）；集成期用 `ps -o rss` 补测。
3. **麦克风实时采集未接**：PoC 为文件回放；「内存环形缓冲、音频不落盘」属集成期（W1×W2 联调）工作。
4. **滚动转写粒度 = VAD 段**：SenseVoice 是整句级识别，段内无法逐字滚动；更细粒度需换流式模型（如 streaming zipformer）或窗口增量解码。
5. **热词是解码后处理**（同音/别名纠偏），非解码期 contextual biasing；如需「提词器优先出词」，升级路径是 zipformer 热词 FST/偏置。
6. **合成语音偏简单**：Tingting 合成音识别近乎无误；真人/嘈杂环境准确率需真机（T1 机型）验证。
7. VAD 合并段（s2+s3）与句间静音阈值有关，`--min-silence` 可调但 0.3s 仍未切开 say 的句间停顿；真人换气间隙通常更长。
