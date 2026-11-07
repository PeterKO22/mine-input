# W27 · screen-context —— 闭合「按键/语音 → 读屏 → 理解与推荐」环

> 需求：用户原话「按键（包括语音快捷键）即读取屏幕，这样才能更好的给出理解和推荐」；
> 需求文档 v1.0 C1（Mac）：「按下键盘时触发屏幕快照→OCR、系统音频→ASR 转写（防抖 1–2s）；
> 仅输入时采集，无持续录音」。本报告为 W27 轮次的实现与验收记录（探针/实测输出在 §5）。

## 1. 环路总览（本轮闭合的部分）

```
按键（SquirrelInputController.handle keyDown）─┐
PTT 语音触发（右⌘按住 / ⌃⌥M 兜底键）─────────┼→ W12C1Collector.onInputEvent()（统一入口）
                                                │   防抖 1–2s（默认 2s）· 同一输入会话内合并
                                                ▼
                        屏幕快照（ScreenCaptureKit / 注入等价截屏帧）
                                                ▼
                        Vision OCR（zh-Hans/en-US，全文仅内存）
                                                ▼
                 上下文存储 ScreenTextContext（截断拼接环，仅内存）
                        │                                │
                        ▼                                ▼
   SuggestContext.screenText（推荐链：             记忆层 JSONL「情境」
   智能候选 + ⌥Esc 提词浮层请求链）               situation.screen_text（仅本地）
                        │
                        ▼
        后端请求体 /v1/suggest（screen_text 字段；仅用户自建 Hub）
```

## 2. 接线（任务 (1)）

- **统一入口** `W12C1Collector.onInputEvent(_:appId:secureInput:completion:)`
  （`macos/w12/src/W12C1Collector.swift`），事件 `W12InputTrigger`：
  - `.keystroke`：SquirrelInputController 按键事件（`W12SquirrelGlue.intercept`，由
    handle() 转发）；
  - `.pttStart`：PTT 语音触发——右⌘按住 / ⌃⌥M 兜底键（`W7PttController.startCapture` →
    `w7ShowRecordingHint` → `W12SquirrelHooks.notePttStart`）→ **开语音触发窗并即时读屏**；
  - `.pttEnd`：PTT 结束（`notePttEnd`）收口触发窗，不采集。
  - 旧入口 `noteKeystroke/notePttStart/notePttEnd` 保留并转发 `onInputEvent`（兼容不回归）。
- **防抖与合并**：`settings.debounceSeconds`（1–2s，默认 2s）；同一输入会话（事件间隙 ≤
  防抖窗的连续段）内多次触发合并为一轮采集（防抖窗内至多一轮，NFR5）。C1 关时直接拒、
  **不触碰防抖状态**（开启 C1 后首个按键立即可采，不被关着时的按键挤占防抖窗——探针实测踩到后修正）。
- 采集链照旧：快照 → Vision OCR → `ocr_digest`（仅摘要/长度）入库 + OCR 文本摘要化入
  `ScreenTextContext`（不落原图、不落全文入库）。

## 3. 截断与拼接策略（任务 (2)，唯一规格源 `context/Sources/ContextCore/ScreenTextContext.swift`）

1. **单帧截断**：每帧 OCR 文本先压空白（连续空白/换行 → 单空格），再取**头部 400 字符**，
   超长补 `…` 尾标（屏幕文本无固定阅读顺序，保头部最稳定）；
2. **环形保留**：只留最近 **3 帧**（新帧挤掉最旧帧）——「近期 OCR 摘要」= 最近几帧，不做全文累积；
3. **拼接**：**新 → 旧**（最新帧在前），帧间 `\n` 分隔；
4. **总量截断**：拼接结果取**头部 1200 字符**，超长补 `…`（新帧在前 → 尾截断先丢最旧帧内容）；
5. **清空即失忆**：`clear()`——C1 关闭（`W12Privacy.disableC1`）、一键清空（
   `MemoryPrivacy.clearAll`，含记忆层）都清环。
- 全程仅内存（不落盘）；C1 默认关 → 默认空环、`screenText` 默认空串。

## 4. 推荐链与记忆层（任务 (2) 其余）

- `SuggestContext` 增 `screenText`（默认空串）；`HubSuggestBackend.requestBody` 带
  `screen_text`（空串也带键，契约稳定；请求只去用户配置的 Hub base_url）。
  智能候选与 ⌥Esc 提词浮层同走 SuggestContext→SuggestBackend 请求链（平价表 #3 口径），
  `W12PrompterOverlay.toggle/show` 增 `screenText` 参数，由
  `W12C1Collector.makeSuggestContext(...)` 统一填充——**门禁**：C1 开 ∧ 未熔断 ∧ 非密码框
  才非空，否则空串（零带出）。CLI 侧 `contextctl suggest --screen-text` 同字段。
- 记忆层：`Situation.screenText`（JSONL 键 `screen_text`，§15.1 W27 扩展键；nil 缺省省略，
  旧行为不漂移）；`MemoryPairing.pair(..., screenText:)` 注入（**仅 consent=c1 记录**可携带）；
  `memoryctl pair --screen-text`；检索命中面含 screen_text（MemoryStore/W20MemoryStore）。
  **同步/ingest 导出不含 screen_text**（MemorySync 只映射摘要列）——屏幕文本只进本地记忆。
- W20 `W20Situation` 同步补 `screen_text`（⌥M 编辑重写经原始 JSON 字典合并，不丢字段；导出 round-trip 保真）。

## 5. 同意与隐私（任务 (3)）

- **W12Privacy 显式同意门沿用**（默认关；`enableC1(explicitConfirm: true)` 才开，不显式确认拒开）；
  新增 `consentTitle/consentText`（用途 / 范围 / 随时可关 三项说清）。
- **⌥M 管理浮层**（W20MemoryPanel）顶部加 **C1 开关 + 状态显示**（`W20C1Control` 抽象，
  生产实现 `W20SquirrelC1Control` 与采集链路同源 W12Privacy meta）：开启必弹确认文案
  （取消即拨回，绝不静默开启）；关闭即清屏幕上下文环。状态行如
  「C1：开（屏幕+语音，仅输入时，防抖 2s）」/「C1：关（默认，未采集）」。
- **密码框零采集**：`secureInput`（IsSecureEventInputEnabled）→ 拒收不可关，且
  `makeSuggestContext(secureInput: true)` 的 screenText 恒空（零带出）。
- **熔断**：trip 后触发前查 + 入库前再查（拒收时不入上下文环），screenText 恒空；
  **一键清空**：事件层 + 记忆层 + 屏幕上下文环同清（`MemoryPrivacy.clearAll`）。
- **SECURITY.md / SECURITY.zh-CN.md 数据分类表如实更新**：新增「屏幕 OCR 文本」行
  （本机=仅内存环 + 本地 JSONL `situation.screen_text`；离机=仅 `suggest` 请求
  `screen_text` 去用户 Hub，绝无同步导出/遥测），并更新 OCR/ASR 摘要、JSONL 记忆库、
  suggest 请求行与 macOS 条目段。

## 6. 验收（任务 (5)）——探针/实测输出

### 6.1 W27 e2e 注入探针（`w12ctl w27-e2e`，与 Squirrel 内接线同一 API/同一落库路径；18/18 PASS）

```
== W27 e2e 注入探针（onInputEvent → 快照→OCR→上下文存储→推荐链）==
db: /tmp/w27-e2e-probe.db  image: …/w27-frame-6407F0D2-….png
PASS: 关 C1（默认关）→ 零采集（rows 0 不变）
PASS: 采集入库 event_id=1 digest=摘要（不含全文）
PASS: 同一输入会话内合并（防抖窗内 5 键 → debounced ×5/5）
PASS: 采集日志出现 screen+OCR 条目（ocrDigest 非空 ×1）
PASS: OCR 条目原文零落库（text_in/out 空）
PASS: digest 列绝不含 OCR 全文
PASS: SuggestContext.screenText 非空（近期 OCR 摘要）
PASS: screenText 含屏幕 OCR 内容（截断拼接策略生效）
PASS: ⌥Esc 提词浮层请求链捕获到 screen_text（注入探针断言）
PASS: 密码框（secure input）→ 零采集
PASS: 密码框拒收原因：secure input: auto-paused (cannot be disabled)
PASS: 密码框 → SuggestContext.screenText 空（零带出）
PASS: 熔断 → 零采集
PASS: 熔断拒收原因：circuit breaker tripped: collection stopped
PASS: 熔断 → SuggestContext.screenText 空
PASS: PTT 语音触发（onInputEvent .pttStart）→ 即时读屏入库
PASS: pttEnd 收口触发窗（不采集）
== 结果：ALL PASS ==
```

口径说明：探针以「注入按键事件（appId=com.apple.TextEdit）+ 等价截屏帧（同一
快照→Vision OCR→摘要→入库链路）」驱动打字场景——即验收项「注入探针断言」的落法。

### 6.2 单测/回归（全绿）

| 套件 | 结果 |
|---|---|
| context · ContextCoreTests（11）+ ScreenTextContextTests（8，W27 新增） | 19/19 |
| context · MemoryCoreTests（13）+ MemoryScreenTextTests（5，W27 新增） | 18/18 |
| macos/w12 · W12CoreTests（8，既有不回归）+ W27InputEventTests（7，新增） | 15/15 |
| macos/w20 · W20MemoryStoreTests（7）+ W20ProposalEngineTests（8） | 15/15 |
| build/w7-replay-test.sh（voice/mic/replay_test.py） | PASS 17 / FAIL 0 |
| build/w7-test-rescore.sh（C++ rescore 挂点） | ALL PASS（failures=0） |
| `bash build/build-squirrel.sh`（全 app 目标含 W12/W20 胶水、pbxproj 引入 ScreenTextContext） | **BUILD SUCCEEDED** |

W27InputEventTests 场景：开 C1 打字→screen+OCR 入库+screenText 进 SuggestContext；
同会话合并（6 键→1 轮）；关 C1 零采集；密码框零采集；熔断零采集；PTT 触发即时读屏+
pttEnd 收口；makeSuggestContext 四门禁（关/开/熔断/密码框）。

### 6.3 可复现记录

- `macos/w27/squirrel-w27.patch`：Squirrel pbxproj 编入
  `context/Sources/ContextCore/ScreenTextContext.swift`（FA77/FA78 id）；
  `macos/w27/scripts/apply-w27.sh` 幂等套用（reverse-check 实测与树一致）。
- `w12ctl` 新增 `w27-e2e` 子命令（注入探针入口，exit code = 断言结果）。

## 7. Blockers / 未实测（如实）

1. **真人 TextEdit 打字 GUI e2e 未实测**：需人工安装 dev IME + 真实键入 + 屏幕录制 TCC
   授权弹窗（自动化子代理不做 TCC 授权/覆盖用户输入法）；打字场景已由注入探针
   （同 API/同落库路径）覆盖，真机人工清单：开 C1（⌥M 弹确认文案）→ TextEdit 打字 →
   `sqlite3 interaction.db "select kind,ocr_digest from events"` 见 key_session+ocr_digest
   → ⌥Esc 提词请求带 screen_text（Hub 模式抓包可见）→ 密码框/熔断同探针断言。
2. **真实 ScreenCaptureKit 快照路径**沿用 W12 未改（需 TCC；`w12ctl c1 capture --source screen`
   为实测入口）；探针用文件源等价帧验证链路本身（W12 既有口径）。
3. **Hub 服务端 screen_text 消费未接**：客户端请求体已带 `screen_text`（单测+探针断言），
   hub `/v1/suggest` 后端是否把该字段喂给模型属 TODO-C（真实 AI 来源）范畴；Null/本地后端零变化。
4. **Android**：仅出平价表 TODO-F 卡（本轮零 Android 代码改动，w24-e2e/w16/w14/w11 未重跑）。
5. 备注：代码注释沿用「§15.1」引用（W19 起既有口径），docs/技术方案-v0.4.md 实际无 §15.1 节
   （历史遗留的悬空指针）；`screen_text` 的规格文本以
   `context/Sources/MemoryCore/MemoryRecord.swift` 头注 + 本报告 §3/§4 + SECURITY §3 为准。

## 8. 改动清单

- **新增**：`context/Sources/ContextCore/ScreenTextContext.swift`（上下文存储+策略）、
  `context/Tests/ContextCoreTests/ScreenTextContextTests.swift`、
  `context/Tests/MemoryCoreTests/MemoryScreenTextTests.swift`、
  `macos/w12/tests/W12CoreTests/W27InputEventTests.swift`、
  `macos/w27/squirrel-w27.patch` + `macos/w27/scripts/apply-w27.sh`、本报告。
- **接线/推荐链**：`macos/w12/src/W12C1Collector.swift`（onInputEvent/合并/上下文入环/
  makeSuggestContext/captureSourceOverride 注入口）、`W12SquirrelGlue.swift`（按键+PTT→
  onInputEvent；提词浮层带 screenText）、`W12PrompterOverlay.swift`（screenText 参数）、
  `context/Sources/ContextCore/SuggestClient.swift`（SuggestContext.screenText + requestBody）。
- **记忆层**：`MemoryRecord.swift`（situation.screen_text）、`MemoryPairing.swift`（c1 注入）、
  `MemoryStore.swift`（检索命中 + clearAll 清环）、`memoryctl/MemoryCtl.swift`、
  `contextctl/ContextCtl.swift`（--screen-text）。
- **同意/管理面**：`macos/w12/src/W12Config.swift`（consent 文案 + disable 清环）、
  `macos/w20/src/W20MemoryStore.swift`（W20C1Control + screen_text）、
  `W20MemoryPanel.swift`（C1 开关/状态/确认弹窗）、`W20SquirrelGlue.swift`（同源实现）。
- **文档**：`SECURITY.md` / `SECURITY.zh-CN.md`（§3 数据分类表 + macOS 条目）、
  `docs/平价表-macos-android.md`（#9 + TODO-F）、`macos/w12/tools/w12ctl/main.swift`（w27-e2e）。
