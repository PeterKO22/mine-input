# W31 REPORT — recorder-live-transcript：PTT 录音中实时分段转写（记录员模式）

日期：2026-11-22（CST）
需求（用户原话）：「长按之后，每隔10s或者明显断句时，就应该把之前的内容显示出来
（不需要直接写到输入框，只在输入法的界面上能看到内容就可以，因为后面还可以调整），
这样才像一个记录员」——说的是输入法项目（macos/w7 PTT 语音上屏链）。

---

## 1. 规格定案（唯一事实源：`macos/w7/src/W7RecorderTranscript.swift` 注释与命名常量）

### 1.1 分段触发（任务 (1)）

| 触发器 | 常量 | 语义 |
|---|---|---|
| 10s tick | `W7RecorderTranscriptFormat.segmentTickSeconds = 10.0` | 录音进行中每 10.0s 从**上一切段点**滚动计时（`nextTickAt = 切段时刻 + 10s`），到点把已完成音频段送 `ptt_daemon` 转写（带标点） |
| 明显断句 | `W7RecorderTranscriptFormat.gapSilenceSeconds = 0.6` | 连续静音 ≥ 0.6s 触发一次分段；静音判定 = 采集侧逐块 RMS 启发式（`W7AudioCapture.silenceRMS = 0.01`，16k 转换后），与 daemon Silero VAD 结论对齐的轻量版（免每块过管线） |

- **已完成段**：切段只推进段界（环形缓冲绝对样本位移切片 `[segStart, totalWritten)`），
  音频继续累计不受影响，采集不中断；转写文本追加「显示用实时稿」（稿面）。
- **双触发防重**：一次切段后未有新语音不再送转写（空段只推进段界、不入稿）；
  tick 与断句同刻齐发只出一段（10s 定时点同时顺延）。
- **低置信/空段不入稿**（沿用 W7 启发式）：`low_confidence=true` 或空文本的段
  不进稿面、不进合并稿。
- **daemon 失败**：该段稿面显示「转写暂不可用」（`unavailableMarker`），不入合并稿、
  **不阻断录音**与后续分段（单测实证后续段照常入稿、停止照常合并）。

### 1.2 面板显示（任务 (2)，不进输入框）

- 文案格式（`W7RecorderTranscriptFormat.panelLine`，逐字规格）：
  - 录音/聆听态：`🎙 速记：<已完成段｜…>｜正在听…`；空稿：`🎙 速记：正在听…`；
  - 段间 `｜` 分隔（最新段与前段「分隔」可见）；
  - 稿面正文上限 `bodyMaxChars = 48` 字符：**超长头部截断 + `…`**（保尾部最新内容）；
  - 锁定态（W28）：上一行逐字保留 W28 锁定提示
    `🔒 已锁定录音中…（可以松开按键了 · 轻点右⌘ 停止上屏 · Esc 取消）` + 换行 + 速记行
    ——多行共存，**锁定态速记稿同样持续更新**（单测逐字断言）。
- 新面板入口 `SquirrelInputController.w7ShowRecorderLine(_:)`（squirrel-w31.patch）：
  只 `showPanel(preedit:)` 写面板，**不写客户端 marked text、不进输入框**；
  不触碰 W12 触发窗收放（无 notePttStart/notePttEnd——开窗仍由 w7ShowRecordingHint 承担、
  收口仍由 w7ShowVoiceStatus 承担，语义与 W27/W28 一致）。
- design-language.md 共存：听写中 = cyan（🎙）、锁定 = gold（🔒）语义映射不变。

### 1.3 停止语义（任务 (3)，不变的用户语义）

- 松手/轻点停止/⌃⌥M 停止 → **最后一段转写** → 等全部在途段落齐（按段序索引归并，
  daemon 严格请求/响应串行到达，乱序亦不影响）→ **全稿合并 → 一次性 `w7CommitVoiceText`
  上屏**（含标点）。
- **标点拼接规则**（`W7RecorderTranscriptFormat.mergedText`，注释即规格）：
  ① 空段跳过；② 相邻边界：前段末字符 ∈ 段尾标点集（`。！？；：，、…!?,.:;」』”’`）
  或后段首字符 ∈ 段首标点/引括集（`“‘『「（(《【[` 及上述停顿标点）→ 直接相连；
  ③ 否则插入「，」（段间本就是语流停顿）。
  例：`今天天气不错。` + `我们去公园吧` + `好啊！` → `今天天气不错。我们去公园吧，好啊！`
  （单测逐字断言）。
- 全稿为空（低置信/空段全被滤）→ 不上屏，面板「没听清，请重说」（沿用 W7 启发式）。
- 空音频诊断（W26）保留：停止时用**全量 PCM** 判「未收到声音，请检查麦克风权限」。
- **Esc 全部丢弃**（录音+锁定+速记稿全清，迟到转写忽略不回填）；组合键取消同语义。

### 1.4 伪时钟单测（任务 (4)）

`macos/w7/tests/test_recorder_transcript.swift`（40 断言）+ runner
`build/w7-test-recorder-transcript.sh`（swiftc 独立编译 `W7RecorderTranscript.swift` +
`W7PttLockMachine.swift`，产物 `build/w7/tests/test_recorder_transcript`，日志
`build/logs/w7-test-recorder-transcript.log`）。**全文零 Thread.sleep、零 TCC、零 launch**
——时钟注入 `session.clock`/`machine.clock`，mock daemon 注入转写结果（同步/挂起回填两态），
音频切段注入 `takeSegmentAudio`。覆盖：

| # | 用例 | 断言要点 |
|---|---|---|
| 1 | 10s tick 触发分段 | 10.0s tick → 恰 1 次转写、切段音频送达、稿面 `🎙 速记：第一段。｜正在听…`、下次定时 ≈10s |
| 2 | 断句触发分段 | 静音 0.55s 不触发；≥0.6s 触发恰 1 次 |
| 3 | 双触发防重 | 断句先切（9.7s）→ 10.0s tick 不补段；tick 先切 → 长静音不补空段（正反两向） |
| 4 | 稿面累加与截断 | 两段 `｜` 分隔逐字；61 字 > 48 上限 → `…`+尾部 48 字逐字 |
| 5 | 停止合并上屏 | 最后一段也转写、收口回调恰 1 次、上屏内容**逐字**=`今天天气不错。我们去公园吧，好啊！`、收口后会话复位；拼接规则补例（后段标点开头直拼/空段跳过/全空空串） |
| 6 | Esc 清空 | 稿面清空、**迟到转写忽略**、取消后 stop 无 commit |
| 7 | 锁定态持续更新 | W28 10.1s 锁定前置 → 锁定提示行逐字在场 + 速记稿随切段更新 + 累加后锁定提示不丢 |
| 8 | daemon 失败 | 稿面「转写暂不可用」、后续分段照常入稿（不阻断录音）、失败段/低置信段不入合并稿 |
| 9 | 低置信/空段 | 不入稿面；全空 → `.empty` 不上屏 |
| 10 | 常量 | `segmentTickSeconds == 10.0`、`gapSilenceSeconds == 0.6` |

## 2. 实现文件清单

| 文件 | 变更 |
|---|---|
| `macos/w7/src/W7RecorderTranscript.swift` | **新增**：W7SegmentResult/W7StopOutcome + W7RecorderTranscriptFormat（文案/截断/标点拼接唯一规格源）+ W7RecorderTranscriptSession（切段调度/稿面/停止收口，注入式可测） |
| `macos/w7/src/W7PttController.swift` | W7RingBuffer 绝对样本位移 + `pcm16Slice` 切片；W7AudioCapture 逐块 RMS 静音回调（`silenceRMS=0.01`）+ `segmentPCM16`；控制器接线 session（转写→daemon、稿面→面板、合并→w7CommitVoiceText）；定时器改为锁定阈值+10s 分段取最近期限；stopAndProcess 改分段收口语义（空音频诊断/识别中/一次性上屏/没听清保留）；cancelCapture 同步 abort 稿面；W26 probeInject 链路不动 |
| `macos/squirrel/sources/SquirrelInputController.swift` | 新增 `w7ShowRecorderLine(_:)`（W31 速记稿面板行；w7ShowLockedHint 保留） |
| `macos/squirrel/Squirrel.xcodeproj/project.pbxproj` | 编入 `../w7/src/W7RecorderTranscript.swift`（FA70…A7/B7） |
| `macos/w7/tests/test_recorder_transcript.swift` | **新增**：40 断言伪时钟单测 |
| `build/w7-test-recorder-transcript.sh` | **新增**：swiftc 独立编译 runner |
| `macos/w31/squirrel-w31.patch` + `macos/w31/scripts/apply-w31.sh` | 可复现记录 + 幂等套用（双向 git apply --check 实测：pre-W31 树正向套用后与工作树逐字节一致；当前树反向 check 通过→already applied 两次幂等） |

## 3. 验收结果（任务 (5)）

| 项 | 命令 | 结果 |
|---|---|---|
| W31 新单测 | `bash build/w7-test-recorder-transcript.sh` | **40/40 ALL PASS**（伪时钟零 sleep，mock daemon） |
| w7 无回归 | `bash build/w7-test-ptt-lock.sh` | **56/56 ALL PASS** |
| w12 无回归 | `cd macos/w12 && swift test` | **20/20**（0 失败） |
| context 无回归 | `cd context && swift test` | **40/40**（MemoryCore 21 + ContextCore 19，0 失败） |
| W27 探针 | `cd macos/w12 && swift run w12ctl w27-e2e` | **ALL PASS**（23/23） |
| W29 探针 | `bash macos/w12/scripts/w29-probe.sh` | **26/26 ALL GREEN** |
| 全 app 目标编译 | `xcodebuild -project Squirrel.xcodeproj -configuration Release -scheme Squirrel build` | **BUILD SUCCEEDED**（W7RecorderTranscript 编入、W7PttController 重构与 w7ShowRecorderLine 均过编译；构建树只编译**未 launch**） |

## 4. 手工验收清单（装机后真人验收——本任务不 install/不 open，留此清单）

1. **主链路**：真人按住右⌘ 说话（>15s、中间自然停顿）→ 录音面板出现
   「🎙 速记：…｜正在听…」且**每 10s 左右或每次明显停顿后稿面滚动追加**已完成段
   （正文不进输入框）→ 松手停止 → 面板「识别中…」→ **全稿一次性上屏**（含标点，
   段间按拼接规则相连）→ 输入框只有这一次提交。
2. **锁定态**：按住右⌘ ≥10s → 「🔒 已锁定录音中…（可以松开按键了 …）」出现且
   **下方速记行持续滚动更新** → 轻点右⌘ 停止 → 一次性上屏。
3. **Esc**：录音/锁定中按 Esc → 稿面与录音全部丢弃，**无任何上屏**。
4. **面板共存**：速记稿只在输入法面板显示，光标处不出现 marked text；
   停止/取消后面板回正常 rime 状态。
5. **异常路径**（可选）：daemon 未起/杀掉 ptt_daemon → 录音继续、稿面该段显示
   「转写暂不可用」，停止后已成功段仍合并上屏；全程麦克风静音 → 停止提示
   「未收到声音，请检查麦克风权限」；说话但全低置信 → 「没听清，请重说」。

## 5. 红线自查

- ✅ 伪时钟零 sleep：新单测全量注入 `clock`，无 Thread.sleep；防抖/阈值/10s/0.6s 全走命名常量+注入时钟。
- ✅ 构建树 Squirrel.app **未 launch**（仅 `xcodebuild build`）；本任务**未 install、未 open** 装机 bundle。
- ✅ 未碰 `.github/`、`docs/RELEASE-NOTES*`、`config/ai*`。
- ✅ 音频不落盘语义不变（切片/转写全在内存，stdin/stdout base64 JSON）。
- ✅ 提交前缀 `W31: `。

## 6. 如实标注（语义边界与已知限制）

- **未装机**：W28/W29/W30 批次同样未装机，用户实测的仍是旧构建；本批全部验收为
  单测+探针+构建级，真人手感（面板渲染多行 preedit 的实际视觉、真机 IME 弹窗）
  留待 §4 装机清单。
- 「每 10s」实现为**从上一切段点滚动计时**（断句切段后重新计 10s），避免同刻双触发；
  与用户「每隔10s…显示之前的内容」语义一致。
- 断句启发式为 Swift 侧 RMS 静音（≥0.6s），非 daemon VAD 逐窗输出（免每块过管线的
  实时性取舍）；如需与 Silero VAD 严格对齐可在后续把 daemon 的 VAD 段界回传接入。
- 转写失败段只上稿面标记「转写暂不可用」、**不重试不入合并稿**（不阻断录音优先）；
  如需失败重试属后续增强。
- 60s 环形缓冲上限不变：切段每 ≤10s 一次且空段也推进段界，正常不会越窗；
  极端情况下（>60s 无任何切段条件）切片按环形窗口自动夹取（丢最旧），属既有上限行为。
- `w7ShowLockedHint()` 保留未删（W28 补丁记录的接口），W31 起锁定面板由
  合成行（锁定提示行+速记行）统一渲染。
- daemon 客户端严格请求/响应串行，段落结果按段序索引归并——在途段落晚到不影响合并顺序。
