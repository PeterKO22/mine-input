# W7 macos 集成交付报告 — PTT 语音上屏 + 候选重排挂点

> 车道：W7 macos 集成（Wave 2）｜日期：2026-11-04｜环境：macOS 27.0.1 arm64 / Xcode 27.2
> 范围：`macos/`（含 `macos/w7/` 实现件）、`voice/mic/`、`build/`（目录所有权内全部产物）
> 依据：docs/开发任务计划.md W7 任务书 + §3 约定；W1/W2/W3 报告与 `ai/spi/ai_assist.h` 契约

---

## 0. 一句话结论

**语音与 AI 挂点已真正接进 Squirrel-dev：(a) 右⌘按住说话 → AVAudioEngine 16k mono 环形缓冲（不落盘）→ W2 管线 → commit 上屏（Esc 取消 / 低置信提示重说 / ⌃⌥M 兜底开关），W2 核心抽为 `voice/mic/` 可复用模块（17/17 回放断言通过）；(b) 候选链经 `ai/spi/ai_assist.h` rescore 挂点（Null 后端 + TimeoutAssist 800ms 弃本轮不阻塞上屏 + 审计每轮恰一条），22 项挂点单测全过，候选区常规/智能两组可区分；`bash build/build-squirrel.sh` 重跑 EXIT=0（BUILD SUCCEEDED）并经 `install-dev.sh` 更新安装 Squirrel-dev.app。** 实机 TextEdit 手工步骤见 §6（本环境禁 computer_use，需人工执行）。

---

## 1. 交付物清单

| 路径 | 说明 |
|---|---|
| `voice/mic/pipeline.py` | W2 PoC 核心抽取：`AsrPipeline`（VAD→SenseVoice int8→CT-Transformer 标点→热词 + 低置信启发式） |
| `voice/mic/ptt_daemon.py` | 常驻守护进程：JSON-line 协议，模型常驻，PCM16 base64 内存传递（音频不落盘） |
| `voice/mic/ptt_client.py` | daemon Python 客户端（Swift 侧同协议的参考实现） |
| `voice/mic/replay_test.py` | W7 (a) 采集→管线脚本化回放验证（17 项断言） |
| `voice/mic/README.md` | 模块用法 / 协议 / 低置信启发式说明 |
| `macos/w7/W7RescoreHook.{h,cc}` | C++ rescore 挂点（包 TimeoutAssist+Null 后端+审计桩；分组纯函数可单测） |
| `macos/w7/src/W7RescoreBridge.{h,mm}` | ObjC++ 桥（Swift↔C++，经 Squirrel-Bridging-Header 暴露） |
| `macos/w7/src/W7PttController.swift` | PTT 状态机 + AVAudioEngine 采集（16k mono 环形缓冲）+ daemon 客户端 |
| `macos/w7/tests/test_rescore_hook.cc` | W7 (b) rescore 挂点单测（22 项断言） |
| `build/squirrel-w7.patch` | Squirrel 集成补丁（唯一事实源：SquirrelInputController / Bridging-Header / Info.plist / pbxproj） |
| `build/build-squirrel.sh` | 更新：dev 补丁后套用 squirrel-w7.patch（幂等可重跑） |
| `build/w7-replay-test.sh` / `build/w7-test-rescore.sh` | 两项自动化验证脚本（日志 → `build/logs/w7-*.log`） |
| `build/install-dev.sh` | 更新：打印 W7 手工测试步骤（A/B 两条） |
| `macos/W7-REPORT.md` | 本报告 |

**目录纪律**：只写了 `macos/`、`voice/mic/`、`build/` 三处；`voice/poc/`、`ai/`、`core/` 未动（`ai/spi/timeout_assist.cc`、`ai/backends/null/null_ai_assist.cc` 被 pbxproj 以只读方式编译进 app）。

---

## 2. (a) PTT 语音上屏

### 2.1 数据流

```
右⌘ 按住（flagsChanged，单修饰键）／⌃⌥M 兜底（latch）
   → AVAudioEngine inputNode.tap（原生采样率）→ AVAudioConverter → 16k mono f32
   → W7RingBuffer（60s 环形，纯内存，满则覆盖最旧）
松开 ⌘ ／ 再按 ⌃⌥M ／ Esc（取消，丢弃）
   → 环形缓冲导出 PCM16LE（内存 Data）→ base64 JSON 行 → pipe
   → voice/mic/ptt_daemon.py（常驻：Silero VAD 流式切段 → SenseVoiceSmall int8
     → CT-Transformer int8 标点 → hotwords.txt 热词纠偏）
   → low_confidence？面板提示「没听清，请重说」（不 commit）
   → 否则 SquirrelInputController.commit(string:) 上屏
```

### 2.2 实现要点

- **单修饰键 flagsChanged 监听**（`W7PttController.interceptFlags`）：仅当 `keyCode==0x36(kVK_RightCommand)`、按下时 `now==[.command]`（忽略 capsLock）才起录；录音中出现 shift/ctrl/option = 组合键用途 → 取消录音并放行原事件；右⌘释放 → 结束并处理。消费的事件不进 rime（`handle()` 顶部拦截，`return true`）。
- **兜底组合键开关**：⌃⌥M（latch：按一下开始、再按一下结束上屏），供右⌘冲突/不便按住时使用。
- **Esc 取消**：录音中 Esc → 丢弃环形缓冲、不送识别、面板提示「已取消录音（Esc）」。
- **音频不落盘**：tap 回调只写内存环形缓冲；导出的 PCM16 走管道 base64（daemon 解码为 numpy 直接进管线）；进程全程无音频文件 IO（回放测试 §2.3 断言 4 实测：audio/tmp/cwd 三处前后清单零增长）。
- **低置信不瞎猜**：SenseVoice int8 无校准后验 → 启发式（VAD 无语音段 / 转写空 / 无汉字 / 汉字密度<0.25 字每秒）判 `low_confidence`，Swift 侧不 commit、提示重说；`confidence`（汉字密度/4.5 字每秒）随结果返回仅作参考。
- **模型常驻**：daemon 启动即 warmup（加载 0.4s 一次付），此后每轮只付推理（s1–s5 单句 52–132ms，多段 27.6s 音频 326ms）；20s 看门狗防挂死（超时重启 daemon，不阻塞 IMK）。
- **W2 核心抽取**：`voice/mic/pipeline.py` 与 `asr_poc.py` 同源算法（0.5s 分块喂 VAD、段边界 ±0.25s pre-roll、标点去重、两级热词纠偏），抽为 `AsrPipeline` 类；`voice/poc/` 一字未动（热词表只读复用）。

### 2.3 自动化实测：采集→管线脚本化回放（`bash build/w7-replay-test.sh`）

W2 样音按采集侧同款形态（16k mono PCM16 bytes，全程内存）走 daemon 协议 = Swift 侧同链路，**17/17 PASS**（全文 `build/logs/w7-replay-test.log`）：

```
[PASS] daemon ping / warmup 模型常驻（load_ms={vad:8.7, asr:297.5, punct:46.2} hotwords=8）
1) 转写正确性（期望=W2-REPORT §5）：s1–s5 与 benchmark_multi 逐字命中（6/6）
2) 低置信不瞎猜：1s 静音 / 空音频 / 0.3s 杂音 → low_confidence=true 且文本空（3/3）
3) 热词纠偏：s3 热词关→「可送」原样；热词开→纠正「可颂」（2/2）
4) 音频不落盘：audio / tmp / cwd 前后清单零增长（3/3）
5) 常驻多轮：连续两轮互不串扰（VAD 轮间 reset）（1/1）
== 汇总: PASS 17 / FAIL 0 ==
```

延迟（模型常驻后，daemon 协议回放）：

| 文件 | 音频s | 段数 | VADms | ASRms | 标点ms | 热词ms | 总ms |
|---|---|---|---|---|---|---|---|
| s1.wav | 4.16 | 1 | 9.4 | 41.4 | 1.4 | 57.9 | 110.2 |
| s2.wav | 5.69 | 1 | 12.6 | 54.2 | 2.4 | 2.0 | 71.5 |
| s3.wav | 4.08 | 1 | 10.5 | 44.2 | 2.1 | 1.6 | 58.6 |
| s4.wav | 4.29 | 1 | 9.8 | 41.7 | 1.8 | 1.3 | 54.8 |
| s5.wav | 5.36 | 1 | 11.8 | 50.0 | 2.2 | 1.7 | 65.8 |
| benchmark_multi.wav | 27.58 | 4 | 60.7 | 247.0 | 9.4 | 7.7 | 325.8 |

对照 NFR2（松开→上屏 ≤1.5s）：管线 52–326ms + commit IO，**达标**（不含麦克风采集与 TCC 授权，见 §7）。

---

## 3. (b) 候选重排挂点

### 3.1 结构

```
SquirrelInputController.rimeUpdate()（每次候选链刷新）
   → w7ShowWithRescore()：常规组（librime 原序）立即 showPanel —— 不等 AI、不阻塞
   → W7RescoreBridge.rescoreWithPreedit…（ObjC++ 桥）
   → mine::w7::RescoreHook::request()（macos/w7/W7RescoreHook.cc）
   → TimeoutAssist.rescoreAsync（ai/spi/timeout_assist.cc，W3 原件只读编译）
       ├─ 后端：NullAiAssist（本阶段「验证挂接」；换真实后端零改动）
       ├─ 800ms 看门狗：超时弃本轮（kTimeout，迟到结果丢弃），绝不阻塞上屏
       └─ 审计桩：每轮恰记一条 AuditRecord（MemoryAuditSink，只记字段）
   → 回调恰一次 → group() 出智能组（越界条目滤除、保持后端序）
   → 主线程合并重绘（generation 过期判定：用户已继续打字则丢弃本轮）
```

### 3.2 常规/智能两组可区分（候选区）

- **常规组**：librime 当前页原序、原标签（1..8），数字键选择路径不变；
- **智能组**：rescore 输出 top-K（`W7SmartTopK`，默认 3）追加在常规组后，标签 `智1..智K`、评论 `⚡AI`（accent 高亮，走 ReservedProperty `commentHighlight` 既有语义）；
- 鼠标点选智能组条目经 `w7DisplayToRime` 映射回 rime 候选索引（`selectCandidate` 已改映射；C++ `group()` 与 Swift 合并两层都过滤越界文本）；
- Null 后端阶段智能组与常规组内容相同（rescore 原样返回 = 挂接验证的预期形态）；真实后端接入后两组出现差异，UI 零改动。

### 3.3 自动化实测：rescore 挂点单测（`bash build/w7-test-rescore.sh`）

`macos/w7/tests/test_rescore_hook.cc` 独立编译（clang++ -std=c++17，链 W3 的 timeout_assist.cc + null_ai_assist.cc），**22/22 PASS**（全文 `build/logs/w7-test-rescore.log`）：

```
1) Null 后端验证挂接：回调恰一次 / kOk / 智能组==常规组 / 审计恰一条（4/4）
2) 异步不阻塞 + 800ms 弃本轮：request() dispatch=0ms（<100ms 断言）；
   超时轮 953ms 判负（700–1400ms 窗口断言）/ kTimeout / 智能组为空 /
   后端 1500ms 迟到结果丢弃（回调计数恒 1）/ 超时轮审计恰一条（8/8）
3) 审计桩每轮恰记一条：连续 3 轮审计计数 1→2→3、回调各恰一次（4/4）
4) 智能组安全过滤：越界条目滤掉+保持后端序 / kTimeout→空 / kDisabled→空（3/3）
5) 重排后端：智能组按后端序（个/他/人）（1/1）
6) secure_input 语义：kDisabled 分组不出智能组 + 后端可注入（2/2）
== 汇总: ALL PASS（failures=0） ==
```

「审计桩每轮恰记一条」的证据链：`CountingAuditSink` 包在真实审计桩前计数，`auditCount()` 逐轮 +1（含超时轮）；TimeoutAssist 保证先记审计后派回调。

---

## 4. 构建与安装实测

**`bash build/build-squirrel.sh` 重跑**（验收命令）：

```
build/squirrel-dev.patch already applied
build/squirrel-w7.patch already applied
** BUILD SUCCEEDED **          （xcodebuild，Release，arm64，MACOSX_DEPLOYMENT_TARGET=13.0）
== artifact == macos/squirrel/build/Build/Products/Release/Squirrel.app
  "CFBundleIdentifier" => "im.rime.inputmethod.Squirrel.dev"（TIS/.dev.Hans/.dev.Hant、
  Squirrel_Dev_Connection、RimeUserDir=~/Library/Rime-mine-dev 均保持 W1 dev 隔离）
BUILD_EXIT=0                   （完整日志 build/logs/w7-build-rerun.log）
```

**W7 集成编译进 app 的实物证据**（`nm`/`strings` 于 Squirrel 可执行文件，223 个 w7 符号）：

```
_TtC8Squirrel15W7PttController（Swift PTT 状态机：startCapture/cancelCapture/stopAndProcess…）
W7RescoreBridge rescoreWithPreedit:textBefore:candidates:callback:（ObjC++ 桥）
mine::w7::RescoreHook::request(...)（C++ 挂点，含 TimeoutAssist/NullAiAssist 符号）
```

**`bash build/install-dev.sh` 更新安装**（INSTALL_EXIT=0，日志 `build/logs/w7-install-dev.log`）：

```
== [1/4] 安装 ~/Library/Input Methods/Squirrel-dev.app ==（ad-hoc codesign，arm64 thin）
   安装后 Info.plist 实测含：W7VoiceEnabled=true、W7RescoreEnabled=true、W7SmartTopK=3、
   W7VoicePython/W7VoiceDaemon/W7Hotwords（dev 路径）
== [2/4] 部署并验证 RIME 用户目录 ~/Library/Rime-mine-dev ==（rime_deployer + console 五组实测通过）
== [3/4] 注册输入源（dev）==（--register-input-source 执行）
```

**补丁可复现性**（W1 同标准）：在 pristine 上游克隆（d220b92）上依次 `git apply`：
`squirrel-dev.patch` ✓ → `squirrel-w7.patch` ✓（`git apply --check` 全过）。

**W7 源码与补丁的关系**：`macos/w7/` 为新增源码唯一事实源，pbxproj 以 `../w7/...`
相对路径直接编译（无拷贝步骤）；对 Squirrel 既有 4 文件的修改全部收敛在
`build/squirrel-w7.patch`（前置于 dev 补丁的上下文由脚本顺序保证：dev → w7）。

---

## 5. 配置项（resources/Info.plist，随补丁注入）

| 键 | 默认值 | 作用 |
|---|---|---|
| `W7VoiceEnabled` | true | PTT 语音总开关（关 = 右⌘/⌃⌥M 全部放行 rime） |
| `W7RescoreEnabled` | true | 候选重排挂点开关（关 = 常规组直达，零 AI 调用） |
| `W7VoicePython` | `~/AITECreate/mine-input/voice/.venv/bin/python` | daemon 解释器（dev 机器路径） |
| `W7VoiceDaemon` | `~/AITECreate/mine-input/voice/mic/ptt_daemon.py` | 管线守护进程 |
| `W7Hotwords` | `~/AITECreate/mine-input/voice/poc/hotwords.txt` | 热词表（只读复用 W2 的） |
| `W7SmartTopK` | 3 | 智能组展示条数 |

> FR6「默认全关」的用户级语义由上层设置界面持有（技术方案 §7）；W7 dev 构建默认开
> 以便验收挂接，切换即改上述两布尔键，无需重编译（Info.plist 热改后重启输入法）。

---

## 6. 手工测试步骤（TextEdit 实操；本环境禁 computer_use，需人工执行）

准备：`bash build/build-squirrel.sh && bash build/install-dev.sh`（本文档 §4 已实测通过）；
系统设置 → 键盘 → 输入法 → 添加「Squirrel Dev」（源 ID `im.rime.inputmethod.Squirrel.dev.Hans`），
必要时注销重登刷新输入法列表。

### (a) PTT 语音上屏

1. **麦克风授权**：首次按住右⌘ 会触发 TCC 授权弹窗（或到 系统设置→隐私与安全性→麦克风
   打开「Squirrel Dev」）。这是运行时手工步骤，无法脚本化。
2. 打开 TextEdit 新建纯文本，切到「Squirrel Dev」。
3. **按住右⌘（单独一键）说话**「今天天气不错」→ 面板出现「🎙 正在聆听…」→ **松开** →
   约 0.5s 内「今天天气不错。」上屏（管线延迟见 §2.3 表）。
4. **Esc 取消**：按住右⌘ 说话中途按 Esc → 提示「已取消录音（Esc）」，无文本上屏。
5. **低置信不瞎猜**：按住右⌘ 只吹气/沉默 1–2 秒后松开 → 提示「没听清，请重说」，无文本上屏。
6. **兜底开关**：按 ⌃⌥M → 开始录音（面板提示同 3）→ 再按 ⌃⌥M → 结束并上屏。
7. **组合键不误触**：录音中按住 shift/ctrl/option（如想 ⌘C）→ 取消录音并正常放行该组合键。
8. 说「我在星巴克点了一杯拿铁和一个可颂面包」→ 热词纠偏生效（可颂，非可送）。

### (b) 候选重排挂点

1. TextEdit 中敲 `nihao` → 候选栏先出现常规组（1..8，拼音/五笔原序）——**立即出现，不等 AI**；
2. ~1 秒内候选栏追加「智1 ⚡AI / 智2 ⚡AI / 智3 ⚡AI」智能组（⚡ 评论为 accent 色）——
   **Null 后端阶段智能组内容与常规组前三相同，属预期（挂接验证）**；
3. 点「智2」→ 正常上屏对应候选（映射回 rime 索引）；数字键 1–8 选择行为不变；
4. 快速连打（每键一轮 rescore）→ 上屏无任何延迟感（800ms 弃本轮不阻塞；打字越快智能组越常被 generation 过期丢弃，属预期）；
5. 把 Info.plist `W7RescoreEnabled` 改 false 重启输入法 → 智能组不再出现、常规组行为不变。

---

## 7. 遗留与 blocker（诚实）

**无硬 blocker。** 遗留：

1. **实机手工上屏未执行**：TextEdit 打字、按住右⌘ 真人说话、候选栏目测属人工步骤（本环境禁 computer_use）。可自动化部分已全部实测（§2.3 / §3.3 / §4）。**麦克风 TCC 授权对 IMK 进程的实际效果未实测**——若人工测试发现输入法进程拿不到麦克风（macOS 对 IMK 的 TCC 归因未知），降级方案是独立菜单栏小工具（采集→管线→剪贴板，daemon 协议现成）；任务书的降级触发条件（IMK 集成被环境阻塞 >2h）**未达成**（集成构建/安装全通），故未交付该小工具。
2. **secure_input（密码框/支付）判定未接**：IMKTextInput 无公开安全输入态 API，`AiContext.secure_input` 恒 false；W3 的 kDisabled 语义已在挂点单测 §3.3-6 覆盖（分组行为 + 后端可注入），接判定后零改动。
3. **Null 后端阶段智能组与常规组相同**：按任务书「先接 Null 后端验证挂接」执行；真实 GGUF 后端（M3+）换入即出现差异，SPI 同签名零改动。
4. **低置信是启发式**（汉字密度 + VAD 判定），SenseVoice int8 无校准后验；阈值（0.25 字/秒、4.5 字/秒基准）可调（`voice/mic/pipeline.py`）。
5. **每次候选刷新一轮 rescore**：W3 TimeoutAssist 每轮 2 线程（调用+看门狗），高频打字下线程数可观；M3 真实后端时按 W3 遗留 3 换线程池 + 加节流。
6. **dev 路径硬编码**：daemon/解释器/热词路径在 Info.plist（`~/AITECreate/mine-input/...`），换机器需改键；正式打包应改为 app bundle 内资源 + 相对路径。
7. **两组区分是标签+评论级**（智N + ⚡AI accent）；候选区分隔线/分区排版属 SquirrelView 主题层改造，留待设计定稿后做。
8. **W1 遗留的 wubi 句子噪音、z 反查重叠等**（W1-REPORT §6）不受 W7 影响，未处理。

---

## 8. 验证命令速查

```bash
# W7 (a) 采集→管线回放（17 断言）
bash build/w7-replay-test.sh            # 日志 build/logs/w7-replay-test.log
# W7 (b) rescore 挂点单测（22 断言）
bash build/w7-test-rescore.sh           # 日志 build/logs/w7-test-rescore.log
# 集成构建 + 安装（幂等可重跑）
bash build/build-squirrel.sh && bash build/install-dev.sh
```
