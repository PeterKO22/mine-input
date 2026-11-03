# W12 macos-C1 交付报告 — 上下文引擎 C1 采集 MVP + 三线接线

> 车道：W12 macos-C1（Wave 3）｜日期：2026-11-04｜环境：macOS 27.0.1 arm64 128GB / Xcode 27.2 / Swift 6.4.2
> 范围：`macos/`（含 `macos/w12/` 实现件）、`context/`（扩展，additive）｜依据：docs/开发任务计划.md W12 任务书 + §3 约定、
> macos/W7-REPORT.md、context/W9-REPORT.md + context/README.md、voice/W2-REPORT.md、docs/技术方案-v0.4.md §8、docs/需求文档-v1.0.md FR4/FR5

---

## 0. 一句话结论

**C1 采集 MVP 已真实接通并脚本化实测：仅输入时触发（PTT 期间 + 按键触发窗，防抖 2s）→ 屏幕快照帧→Vision OCR→`ocr_digest` 摘要入库、音频→W2 管线（voice/mic/ptt_daemon）→`asr_digest` 入库（仅摘要/长度，原图/全文实测 0 落库）；W7 的输入会话/语音会话/候选选择事件经唯一入口 W12EventBridge 上报 W9 InteractionStore（Squirrel 内已挂点并编入 app）；⌥Esc NSPanel 提词浮层（W9 SuggestClient，Hub SSE/Null 双模）流式 Δ 实时刷新→Tab/点按采纳→`suggestion_feedback` 入库；C1 开关显式（默认关）、密码框自动停、黑名单跳过、熔断立即停全部有实测输出。`bash build/build-squirrel.sh` 重跑 BUILD_EXIT=0 并 `install-dev.sh` 重装（W12 符号实证）；既有 W7/W9 测试全绿（回放 17/17、挂点 22/22、W9 11/11）。** 真屏幕快照与浮层 GUI 的实机行为受本会话 TCC/人工限制（§8 诚实记录）。

---

## 1. 交付物清单

| 路径 | 说明 |
|---|---|
| `macos/w12/src/W12C1Collector.swift` | C1 采集编排：仅输入时触发（PTT 期间+按键触发窗）+ 防抖 2s（`decideTrigger` 纯函数可单测）；OCR/ASR 摘要入库；四道门禁（C1 显式/熔断/密码框/黑名单） |
| `macos/w12/src/W12ScreenCapture.swift` | ScreenCaptureKit 屏幕快照（SCShareableContent→SCScreenshotManager；TCC 拒→明确报错）+ 文件帧源（同一 OCR 链路） |
| `macos/w12/src/W12OCR.swift` | Vision OCR（zh-Hans/en-US、accurate+纠错）→ 摘要 |
| `macos/w12/src/W12AsrClient.swift` | voice/mic/ptt_daemon.py JSON-line 客户端（W2 管线，与 W7 同协议）+ WAV→16k mono PCM16（AVAudioConverter，内存） |
| `macos/w12/src/W12Digest.swift` | 摘要/长度工具：`sha256:<16hex> len:<n> lines:<m>`（CryptoKit SHA-256；`isSummaryOnly` 防回归） |
| `macos/w12/src/W12EventBridge.swift` | **W7×W9 接线唯一入口**：reportKeySession/reportVoiceSession/reportCandidatePick/reportSuggestionFeedback/reportC1Sample → C0Collector.record* 入库 API |
| `macos/w12/src/W12PrompterModel.swift` | 提词浮层流式模型：SuggestClient（Hub SSE/Null 双模）Δ 帧→实时刷新日志→Tab 采纳（suggestion_feedback 入库） |
| `macos/w12/src/W12PrompterOverlay.swift` | NSPanel 浮层（.nonactivatingPanel/floating，不抢焦点；只建议不上屏，采纳才 commit） |
| `macos/w12/src/W12SquirrelGlue.swift` | Squirrel/IMK 接线（仅编进 app，`#if !W12_STANDALONE`）：⌥Esc 热键、Tab/数字/Esc、C1 输入触发、W7 事件上报 |
| `macos/w12/src/W12Config.swift` | 隐私设置（C1 显式开关 `W12Privacy.enableC1(explicitConfirm:)`，与 W9 剪贴板开关同构）+ `W12StatusColor` 状态条指示色约定 |
| `macos/w12/tools/w12ctl/main.swift` | 脚本化实测 CLI（与 Squirrel 同一套 API；privacy/c1/bridge/prompter/breaker/hub-token） |
| `macos/w12/tests/W12CoreTests/` | 8 用例（全绿）：摘要不落原文/防抖触发窗/隐私门禁/OCR 入库/W7×W9 上报/流式→采纳 |
| `macos/w12/scripts/w12-demo.sh` | 验收序列脚本（全文输出 §7） |
| `macos/w12/squirrel-w12.patch` + `scripts/apply-w12.sh` | Squirrel 树集成补丁（可复现记录；`git apply --reverse --check` 实测过） |
| `macos/w12/README.md` | 组件/用法/隐私红线/指示色约定 |
| `context/Sources/ContextCore/C0Collector.swift`（扩展） | 新增 `recordC1Sample(kind:ocrDigest:asrDigest:)` 入库 API（additive，W9 既有 11 测试不动全绿） |
| `context/Sources/ContextCore/SuggestClient.swift`（扩展） | SSE `event: error` 帧→kError 诚实上报（W10 llama 后端 503 时不再静默变 done）+ 行尾 trim 加固 |
| `context/Package.swift`（扩展） | 显式 products（ContextCore library，供 macos/w12 包依赖） |
| `context/README.md`（扩展） | 「W12 扩展（C1 采集）」一节 |
| `macos/W12-REPORT.md` | 本报告 |

**目录纪律**：只写了 `macos/`（含 `macos/w12/`、`macos/squirrel/` 工作树内 3 文件）与 `context/`；`build/`、`voice/`、`ai/`、`hub/` 未动。Squirrel 工作树改动收敛在 `macos/w12/squirrel-w12.patch`（`build/` 不在本车道所有权内，补丁按约定放 `macos/w12/`）。

---

## 2. (a) C1 采集 MVP

### 2.1 数据流与触发语义

```
触发（仅输入时）：PTT 期间（W7 w7ShowRecordingHint→w7ShowVoiceStatus 窗口）＋按键触发窗（每次 keyDown）
   └─ 防抖 2s（decideTrigger 纯函数：触发窗外不采、2s 内不重采；NFR5）
屏幕：ScreenCaptureKit 全屏快照（SCShareableContent→SCScreenshotManager，一帧 CGImage）
   → Vision OCR（zh-Hans/en-US）→ 摘要 = sha256:… len:N lines:M → events.ocr_digest（kind=key_session）
   ↳ 原图、OCR 全文在摘要后即弃（内存生命周期内），任何路径不落库/不落盘
音频：麦克风/系统音频环回/音频文件 → 16k mono PCM16（内存）→ W2 管线（voice/mic/ptt_daemon：
   Silero VAD→SenseVoice int8→CT-Transformer 标点→热词）→ 摘要 → events.asr_digest（kind=voice_session）
入库前二次门禁 + store.insert 兜底（熔断立即停）
```

### 2.2 硬门禁（隐私红线，顺序即优先级）

1. **C1 默认关、开关显式**：Info.plist `W12C1Enabled=false`；运行时只认 `W12Privacy.enableC1(explicitConfirm: true)`（持久 store meta，跨进程）；两者皆无 → `refused: C1 collection disabled`；
2. **熔断立即停**：W9 `CircuitBreaker`（全局持久）trip 后触发前查 + 入库前再查 + store.insert 兜底拒（§7 步骤 7：trip 前后 COUNT 4==4）；
3. **密码框自动停不可关**：IME 侧传 `IsSecureEventInputEnabled()`（Carbon HIToolbox，实测可调用）→ 一律拒收（§7 步骤 6）；
4. **敏感应用黑名单跳过**：C0Collector.defaultBlacklist（keychain/1Password/Bitwarden/LastPass/KeePassXC）→ `skipped`（§7 步骤 6）。

### 2.3 摘要/长度不落原文（实测）

`ocr_digest`/`asr_digest` 值形如 `sha256:4f241a2e1a108cc3 len:24 lines:1`；单测 `testOCRDigestIngestStoresDigestOnly` 断言 text_in/text_out 空、digest 不含 OCR 文本；demo 步骤 3 全库检索测试文本 **0 命中**（`plaintext hits in db: 0`）。

---

## 3. (b) W7×W9 接线（启用入库 API）

SquirrelInputController 挂点（`macos/w12/squirrel-w12.patch`）→ `W12SquirrelHooks` → `W12EventBridge`（唯一入口）→ C0Collector.record* → W9 InteractionStore：

| W7 事件 | 挂点 | kind | 实测（§7 步骤 8） |
|---|---|---|---|
| 输入会话（上屏） | `commit(string:)` | key_session | event_id=5（text_in=ni hao；text_out 留存默认关为空） |
| 语音会话（PTT 上屏） | `w7CommitVoiceText` | voice_session（C1 开时附 asr_digest） | event_id=6 |
| 候选选择 | `selectCandidate` | candidate_pick | event_id=7（text_in=zni） |
| 提词采纳 | 浮层 Tab/点按 | suggestion_feedback（taken=1） | event_id=8/9（§7 步骤 9） |

细节：语音上屏经 `skipNextCommitReport` 抑制随后 commit 的 key_session 双报；PTT 触发窗由 `w7ShowRecordingHint/w7ShowVoiceStatus` 收放；所有上报带 `IsSecureEventInputEnabled()` 安全输入判定（密码框自动停）。`w12ctl bridge demo` 走与 Squirrel 完全相同的桥 API（同一落库路径），app 侧符号实证见 §6。

---

## 4. (c) ⌥Esc 提词浮层

- **感应点**：Squirrel handle() 拦截 ⌥Esc（keyCode 0x35 + .option）→ 唤起/收起 NSPanel（`.nonactivatingPanel` + `.floating`，不抢焦点；「只建议不上屏」——未采纳前绝不 commit，采纳才经 `w12CommitAdopted` 上屏）；
- **流式**：W9 `SuggestClient`（**Hub `/v1/suggest` SSE / Null 离线双模**，800ms 超时弃本轮 NFR3）→ `W12PrompterModel` 每帧 Δ 实时刷新浮层（Δ 帧带毫秒时标）；语音中随转写增量刷新（`fromVoice`，FR5 感应点 #3）；
- **采纳**：Tab（第 1 条）/ 数字 1-9 选中 / 鼠标点按 → `suggestion_feedback` 入库（shown/taken）→ 关闭；Esc 关闭；
- **实测**（§7 步骤 9）：Null 3×Δ（+66/130/229ms）→done→[TAB] 采纳入库；Hub SSE 3×Δ（+189/339/490ms，hub-stub）→done→[TAB] 采纳入库。浮层快照（ASCII）随每帧重绘即 NSPanel 同数据源。

---

## 5. (d) 隐私设置项 + 状态条指示色约定

- **C1 开关显式**：`W12C1Enabled`（Info.plist，默认 **false**）+ 运行时 `W12Privacy.enableC1(explicitConfirm: true)`（meta 持久，跨进程；`disableC1()` 关）；`w12ctl privacy status|c1 on|off`；子开关 `W12C1Screen`/`W12C1Audio`（默认 true，在 C1 开前提下生效）；
- **状态条指示色约定（文档化，`W12StatusColor`，README 同表）**：

| 状态 | 色值 | 含义 |
|---|---|---|
| 灰 | `#8E8E8E` | 采集关（C1 关：仅 C0 或全关） |
| 青绿 | `#388A83` | 采集正常（C0：输入历史/应用名） |
| 金 | `#D4A857` | C1 采集激活（快照/转写进行中） |
| 红 | `#C0453E` | 熔断开启 / 安全输入（密码框）暂停 |

（色值对齐 design-language：青 `#388A83`、金 `#D4A857`。）

---

## 6. 构建与安装实测（验收命令）

**`bash build/build-squirrel.sh` 重跑**（W12 代码已编入 app 目标；W12Core 10 源 + ContextCore 5 源经 pbxproj FA71/FA72 条目编译）：

```
build/squirrel-dev.patch already applied
（squirrel-w7.patch 无法干净套用 → warning 继续构建，见 §8-5 说明）
** BUILD SUCCEEDED **          （xcodebuild Release arm64，MACOSX_DEPLOYMENT_TARGET=13.0）
== artifact == macos/squirrel/build/Build/Products/Release/Squirrel.app
BUILD_EXIT=0                   （完整日志 build 日志：w12-build*.log）
```

**`bash build/install-dev.sh`**（INSTALL_EXIT=0）：安装后 `plutil -p` Info.plist 实测含
`W12C1Enabled=false（默认关）/W12C1Screen=true/W12C1Audio=true/W12PrompterEnabled=true/
W12PrompterBackend=null/W12HubURL=http://localhost:8088`（W7 六键保持不变）。

**W12 集成编译进 app 的实物证据**（`nm`/`strings` 于已安装 Squirrel 可执行文件，297 个 W12 相关符号）：

```
_TtC8Squirrel14W12C1Collector（C1 采集编排；notePttStart/notePttTranscript…）
_TtC8Squirrel14W12EventBridge（W7×W9 上报唯一入口）
_TtC8Squirrel16W12SquirrelHooks（⌥Esc 拦截/noteVoiceCommit/…）
_TtC8Squirrel18W12PrompterOverlay（NSPanel 浮层）
U  _IsSecureEventInputEnabled   （Carbon 密码框判定，已链接引用）
```

**补丁可复现性**：`macos/w12/squirrel-w12.patch` 以「dev+w7 补丁后状态 → W12 状态」生成，
`git apply --reverse --check` 在当前树实测通过（= 当前树恰为补丁后状态）；pristine 克隆依次
`squirrel-dev.patch → squirrel-w7.patch → squirrel-w12.patch` 即复现。

---

## 7. 验收序列脚本化实测输出（`bash macos/w12/scripts/w12-demo.sh`，EXIT=0）

覆盖：触发采集（防抖）→ OCR 摘要入库 → sqlite3 可查 → 真屏幕快照（TCC）→ ASR 摘要入库 → 隐私负例（密码框/黑名单/C1 关）→ 熔断后停止（COUNT 不变）→ W7×W9 三事件 → ⌥Esc 提词浮层流式刷新（Null+Hub）→ Tab 采纳入库 → 全量计数：

```text
=== 0. 构建与测试（swift build / swift test，W12Core 8 用例） ===
Build complete! (7.96秒)
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.580 (0.581) seconds
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.580 (0.581) seconds
	 Executed 8 tests, with 0 failures (0 unexpected) in 0.580 (0.581) seconds
db: /Users/you/AITECreate/mine-input/macos/w12/.demo/w12-interaction.db

=== 1. 隐私设置：C1 默认关 → 显式开启（开关显式，隐私红线） ===
== W12 隐私设置 ==
C1 总开关: false（Info.plist W12C1Enabled=false + 显式 meta=false；**默认关**）
  子开关: screen=true audio=true
  触发: 仅输入时（PTT 期间 + 按键触发窗），防抖 2s
  安全输入（密码框）: 自动停不可关（IsSecureEventInputEnabled）
  黑名单: 6 个敏感应用，命中跳过
  熔断: breaker=off（trip 后立即停，日志保留不新增）
  上屏文本留存(L3): off（默认）
  状态条指示色约定: 灰#8E8E8E=采集关 / 青绿#388A83=仅C0 / 金#D4A857=C1采集激活 / 红#C0453E=熔断或安全输入暂停
c1 explicit enable: true（meta c1_enabled=1，跨进程生效）
== W12 隐私设置 ==
C1 总开关: true（Info.plist W12C1Enabled=false + 显式 meta=true；**默认关**）
  子开关: screen=true audio=true
  触发: 仅输入时（PTT 期间 + 按键触发窗），防抖 2s
  安全输入（密码框）: 自动停不可关（IsSecureEventInputEnabled）
  黑名单: 6 个敏感应用，命中跳过
  熔断: breaker=off（trip 后立即停，日志保留不新增）
  上屏文本留存(L3): off（默认）
  状态条指示色约定: 灰#8E8E8E=采集关 / 青绿#388A83=仅C0 / 金#D4A857=C1采集激活 / 红#C0453E=熔断或安全输入暂停

=== 2. 触发采集：仅输入时（按键触发窗）+ 防抖 2s ===
test image written: /tmp/w12-shot.png (184587 bytes)
模拟按键 ×4（防抖 2s，仅输入时触发）：
  key#1 t+0.0s → capture=true (input trigger (ptt=false))
    → stored: event_id=1 digest=sha256:4f241a2e1a108cc3 len:24 lines:1
  key#2 t+1.0s → capture=false (debounced (1.0s < 2.0s))
  key#3 t+2.0s → capture=true (input trigger (ptt=false))
    → stored: event_id=2 digest=sha256:4f241a2e1a108cc3 len:24 lines:1
  key#4 t+3.0s → capture=false (debounced (1.0s < 2.0s))
触发采集 2/4 轮（防抖收敛）

=== 3. OCR 摘要入库（ScreenCaptureKit 帧→Vision OCR→摘要；sqlite3 可查） ===
capture source: image file（等价截屏帧）
stored: event_id=3 digest=sha256:4f241a2e1a108cc3 len:24 lines:1
$ sqlite3 -header -column ... "SELECT id,kind,ocr_digest,asr_digest,text_in,text_out FROM events ORDER BY id"
id     kind                    ocr_digest                asr_digest  text_in  text_out
--  -----------  --------------------------------------  ----------  -------  --------
 1  key_session  sha256:4f241a2e1a108cc3 len:24 lines:1
 2  key_session  sha256:4f241a2e1a108cc3 len:24 lines:1
 3  key_session  sha256:4f241a2e1a108cc3 len:24 lines:1
-- 隐私红线验证：OCR 全文/原图不落库（数据库中检索测试文本应为 0 命中）
plaintext hits in db: 0（期望 0）

=== 4. 真屏幕快照（ScreenCaptureKit，需屏幕录制 TCC） ===
refused: capture failed: screen recording TCC denied: Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3801 "用户拒绝了应用程序、窗口、显示器捕捉的TCC" UserInfo={NSLocalizedDescription=用户拒绝了应用程序、窗口、显示器捕捉的TCC}

=== 5. ASR 摘要入库（音频→W2 管线 voice/mic/ptt_daemon→asr_digest，仅摘要/长度） ===
[ptt_daemon] ready (models lazy-loaded)
[ptt_daemon] models loaded in 1149ms ({'vad': 58.544208, 'asr': 983.182958, 'punct': 79.01658300000003})
wav loaded: /Users/you/AITECreate/mine-input/voice/audio/s1.wav pcm16=133170 bytes（16k mono，内存）
stored: event_id=4 digest=sha256:aee62f4e0ec991e3 len:18
[ptt_daemon] bye
$ sqlite3 ... "SELECT id,kind,asr_digest FROM events WHERE asr_digest IS NOT NULL"
id      kind                 asr_digest
--  -------------  ------------------------------
 4  voice_session  sha256:aee62f4e0ec991e3 len:18

=== 6. 隐私负例：密码框自动停 / 黑名单跳过 / C1 关拒绝 ===
-- 密码框（secure input）自动停不可关：
capture source: image file（等价截屏帧）
refused: secure input: auto-paused (cannot be disabled)
-- 敏感应用黑名单（keychain）跳过：
capture source: image file（等价截屏帧）
skipped: blacklisted app: com.apple.keychainaccess
-- C1 关（默认）拒绝采集：
  状态条指示色约定: 灰#8E8E8E=采集关 / 青绿#388A83=仅C0 / 金#D4A857=C1采集激活 / 红#C0453E=熔断或安全输入暂停
capture source: image file（等价截屏帧）
refused: C1 collection disabled (default off; 需显式开启)
  状态条指示色约定: 灰#8E8E8E=采集关 / 青绿#388A83=仅C0 / 金#D4A857=C1采集激活 / 红#C0453E=熔断或安全输入暂停

=== 7. 熔断开关：trip 后一切采集立即停（日志保留不新增） ===
events before trip: 4
breaker: TRIPPED（一切采集立即停；日志保留不新增）
capture source: image file（等价截屏帧）
refused: circuit breaker tripped: collection stopped
wav loaded: /Users/you/AITECreate/mine-input/voice/audio/s1.wav pcm16=133170 bytes（16k mono，内存）
refused: circuit breaker tripped: collection stopped
events after trip: 4（期望 == 4）
breaker: off（采集恢复）

=== 8. W7×W9 接线：输入会话/语音会话/候选选择 → InteractionStore（同一入库 API） ===
== W7×W9 接线：W7 事件 → W9 InteractionStore（同一 API，Squirrel 调用点相同）==
输入会话 key_session: stored: event_id=5
语音会话 voice_session: stored: event_id=6
候选选择 candidate_pick: stored: event_id=7
$ sqlite3 ... "SELECT id,kind,text_in,text_out FROM events WHERE id > 4 ORDER BY id"
id       kind       text_in  text_out
--  --------------  -------  --------
 5  key_session     ni hao
 6  voice_session
 7  candidate_pick  zni

=== 9. ⌥Esc 提词浮层：SSE 流式建议→实时刷新→Tab 采纳（Hub/Null 双模） ===
-- Null 离线兜底：
══ ⌥Esc 提词浮层 · 流式刷新演示（W12PrompterModel，与 NSPanel 浮层同一模型）══
感应点：⌥Esc（IME 热键唤起 NSPanel 流层；语音中随转写增量刷新）
backend: null（离线兜底）  timeout=800ms（超时弃本轮，NFR3）
Δ +   66ms [1] 语音转写——本地兜底建议一  (0.62 null)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 语音转写——本地兜底建议一                 (0.62 null)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +   66ms [1] 语音转写——本地兜底建议一  (0.62 nu
  └────────────────────────────────────────┘
Δ +  130ms [2] 语音转写——本地兜底建议二  (0.51 null)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 语音转写——本地兜底建议一                 (0.62 null)
  │ 2. 语音转写——本地兜底建议二                 (0.51 null)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +   66ms [1] 语音转写——本地兜底建议一  (0.62 nu
  │ Δ +  130ms [2] 语音转写——本地兜底建议二  (0.51 nu
  └────────────────────────────────────────┘
Δ +  229ms [3] 语音转写——本地兜底建议三  (0.44 null)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 语音转写——本地兜底建议一                 (0.62 null)
  │ 2. 语音转写——本地兜底建议二                 (0.51 null)
  │ 3. 语音转写——本地兜底建议三                 (0.44 null)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +   66ms [1] 语音转写——本地兜底建议一  (0.62 nu
  │ Δ +  130ms [2] 语音转写——本地兜底建议二  (0.51 nu
  │ Δ +  229ms [3] 语音转写——本地兜底建议三  (0.44 nu
  └────────────────────────────────────────┘
✓ done +229ms（建议刷新完成）
[TAB] 采纳 → 语音转写——本地兜底建议一  (score=0.62 source=null)
        · suggestion_feedback 已入库（shown=3 taken=1）
-- Hub SSE 流式（localhost:8088）：
hub-token: len=84（register 忽略 409 → token）
══ ⌥Esc 提词浮层 · 流式刷新演示（W12PrompterModel，与 NSPanel 浮层同一模型）══
感应点：⌥Esc（IME 热键唤起 NSPanel 流层；语音中随转写增量刷新）
backend: hub http://localhost:8088  timeout=800ms（超时弃本轮，NFR3）
Δ +  189ms [1] 今天开会——好的，我稍后处理  (0.86 hub-stub)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 今天开会——好的，我稍后处理                (0.86 hub-stub)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +  189ms [1] 今天开会——好的，我稍后处理  (0.86 h
  └────────────────────────────────────────┘
Δ +  339ms [2] 今天开会——请稍等，马上回复  (0.74 hub-stub)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 今天开会——好的，我稍后处理                (0.86 hub-stub)
  │ 2. 今天开会——请稍等，马上回复                (0.74 hub-stub)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +  189ms [1] 今天开会——好的，我稍后处理  (0.86 h
  │ Δ +  339ms [2] 今天开会——请稍等，马上回复  (0.74 h
  └────────────────────────────────────────┘
Δ +  490ms [3] 今天开会——谢谢，收到  (0.61 hub-stub)
  ┌─ ⌥Esc 提词浮层 ─────────────────────────────┐
  │ 1. 今天开会——好的，我稍后处理                (0.86 hub-stub)
  │ 2. 今天开会——请稍等，马上回复                (0.74 hub-stub)
  │ 3. 今天开会——谢谢，收到                   (0.61 hub-stub)
  ├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤
  │ Δ +  189ms [1] 今天开会——好的，我稍后处理  (0.86 h
  │ Δ +  339ms [2] 今天开会——请稍等，马上回复  (0.74 h
  │ Δ +  490ms [3] 今天开会——谢谢，收到  (0.61 hub-
  └────────────────────────────────────────┘
✓ done +490ms（建议刷新完成）
[TAB] 采纳 → 今天开会——好的，我稍后处理  (score=0.86 source=hub-stub)
        · suggestion_feedback 已入库（shown=3 taken=1）
$ sqlite3 ... "SELECT id,kind,suggestion_shown,suggestion_taken FROM events WHERE kind='suggestion_feedback'"
id         kind          suggestion_shown  suggestion_taken
--  -------------------  ----------------  ----------------
 8  suggestion_feedback                 3                 1
 9  suggestion_feedback                 3                 1

=== 10. 汇总（sqlite3 全量计数） ===
$ sqlite3 ... "SELECT kind, COUNT(*) FROM events GROUP BY kind"
       kind          COUNT(*)
-------------------  --------
candidate_pick              1
key_session                 4
suggestion_feedback         2
voice_session               2
$ sqlite3 ... "SELECT COUNT(*) FROM events"
9

=== W12 DEMO: ALL STEPS EXECUTED ===
```

---

## 8. 既有测试仍全绿（W7/W9 不回归 + W12 新增）

```
$ bash build/w7-replay-test.sh        # W7 (a) 采集→管线回放（17 断言）
== 汇总: PASS 17 / FAIL 0 ==           （REPLAY_EXIT=0）
$ bash build/w7-test-rescore.sh       # W7 (b) rescore 挂点（22 断言）
== 汇总: ALL PASS（failures=0） ==      （RESCORE_EXIT=0）
$ cd context && swift test            # W9（11 用例）
Executed 11 tests, with 0 failures (0 unexpected)
$ cd macos/w12 && swift test          # W12 新增（8 用例）
Executed 8 tests, with 0 failures (0 unexpected)
```

---

## 9. 遗留与 blocker（诚实）

1. **真屏幕快照被 TCC 挡住（本会话，非代码缺陷）**：`SCShareableContent` 返回
   `SCStreamErrorDomain -3801 用户拒绝了…TCC`（屏幕录制权限未授予本执行环境）。
   链路本身已用「文件帧源 = 等价截屏帧」走通并入库（demo 步骤 2/3）；授权后同一
   `c1 capture --source screen` / IME 内按键触发即真实截屏。**需要人工在 系统设置→隐私与安全性→屏幕录制 授权后复验。**
2. **系统音频环回（loopback）MVP 以「麦克风 + 音频文件 → W2 管线」落地**：系统声音回环
   需 SCStream 音频采集或虚拟声卡（如 BlackHole），本环境无 TCC/无虚拟设备，未实测；
   asr_digest 链路已用 W2 样音实测（demo 步骤 5：s1.wav→digest len:18）。麦克风 TCC 对 IMK 进程的效果沿用 W7 遗留 1 未决。
3. **⌥Esc 浮层/IME 内行为未实机手测**（禁 computer_use）：热键拦截、浮层绘制、Tab/点按采纳的 GUI 行为需人工按 §10 步骤复验；流式刷新与采纳语义已由脚本化实测覆盖（与 NSPanel 同一 W12PrompterModel）。
4. **Hub /v1/suggest 抖动（W10 车道并行改动）**：实测期间 W10 正在给 hub 换 llama.cpp 真后端，出现 SSE `event: error`（llama 503）间歇窗口。客户端已把 error 帧如实上报为 kError（SuggestClient 扩展）并在 demo 加重试取健康窗口；Hub 健康时 3×Δ+done 实测通过（§7 步骤 9）。属跨车道集成波动，非 W12 缺陷。
5. **build-squirrel.sh 打印 `squirrel-w7.patch 无法干净套用` warning**：因 W12 改动落在 w7 补丁同一批文件（SquirrelInputController/Info.plist/pbxproj），`git apply --check` 上下文重叠；脚本按设计继续构建且 BUILD SUCCEEDED，树状态由 `squirrel-w12.patch` 以「w7 后状态」为基线记录（reverse-check 通过）。若要求零 warning，需把 w12 补丁并入 build/ 脚本（build/ 非本车道所有权，未动）。
6. **防抖语义是「输入触发窗 + 至多 1 轮/2s」**：触发在 keyDown 即时判定（rime 按键流）；若要「静默 2s 后再采」的后沿防抖可换 `decideTrigger` 调用点，纯函数已单测隔离。
7. **keystroke_cadence 未填**（W7 同遗留）：候选/按键事件暂不带节奏统计，字段保留 NULL。
8. **`W12C1Enabled=false` 默认关意味着装机后 C1 不采集**，直到用户显式 `w12ctl privacy c1 on`（或设置界面调 `W12Privacy.enableC1(explicitConfirm:)`）——这是隐私红线的预期形态，不是缺陷。

---

## 10. 验证命令速查

```bash
# W12 单测（8 用例）+ 验收序列（全链路，输出贴 §7）
cd macos/w12 && swift test
bash macos/w12/scripts/w12-demo.sh 2>&1 | tee .demo/demo-output.txt

# 既有测试（应全绿）
bash build/w7-replay-test.sh && bash build/w7-test-rescore.sh
(cd context && swift test)

# 集成构建 + 重装（幂等可重跑）
bash build/build-squirrel.sh && bash build/install-dev.sh

# 手工复验（需人工；本环境禁 computer_use）
# 1. 系统设置→隐私与安全性→屏幕录制/麦克风 允许「Squirrel Dev」
# 2. TextEdit 切「Squirrel Dev」：打字 2s 内至多一轮快照（log 查询 sqlite3 interaction.db 见 ocr_digest）
# 3. ⌥Esc → 浮层出建议（Null 离线或 Hub SSE）→ Tab 采纳上屏；Esc 关闭
# 4. 按住右⌘ 说话松开 → 上屏 + events 多一条 voice_session（C1 开时带 asr_digest）
# 5. 打开密码框（如 系统设置登录框）打字 → 无任何采集（红态）；w12ctl breaker trip → 全停
```
