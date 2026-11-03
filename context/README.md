# context/ —— 上下文引擎 MVP + 交互日志 + 动态提词器（W9，C0 级）

> 里程碑 M5 前置（需求 FR4/FR5）｜依据：docs/技术方案-v0.4.md §8（上下文引擎/提词器）、
> docs/需求文档-v1.0.md FR4/FR5、ai/spi/ai_assist.h（suggest/ingest/InteractionEvent 契约）、
> hub/W4-REPORT.md（/v1/suggest SSE、/v1/ingest）。纯 SwiftPM（系统库：libsqlite3/AppKit/Foundation），零第三方依赖。

## 组件

| 模块 | 文件 | 职责 |
|---|---|---|
| 交互日志 store | `Sources/ContextCore/InteractionStore.swift` | 本地 SQLite：`events` 表逐字段对齐 §8.2 InteractionEvent（ts/device_id/app_id/kind/text_in/text_out/ocr_digest/asr_digest/keystroke_cadence/suggestion_shown/suggestion_taken），时间索引，**可查（list/count）可导（JSONL/CSV）可一键清空（clear）**，`prune` 30 天滚动 |
| C0 采集器 | `Sources/ContextCore/C0Collector.swift` | frontmost 应用名（**NSWorkspace**）；输入会话事件入库 API（`recordKeySession/recordVoiceSession/recordCandidatePick/recordSuggestionFeedback`，**供 W7 上报**）；安全输入自动暂停；敏感应用黑名单；**剪贴板采集默认关**（显式开关，且只记摘要/长度不记内容） |
| 熔断开关 | `Sources/ContextCore/CircuitBreaker.swift` | 全局标志（持久在 store meta，跨进程生效）：`trip()` 后**一切采集立即停，日志保留不新增**；`reset()` 显式恢复 |
| suggest 客户端 | `Sources/ContextCore/SuggestClient.swift` | `HubSuggestBackend`：POST `/v1/suggest` SSE（`event: suggestion`→kDelta，`event: done`→kDone）；`NullSuggestBackend` 离线兜底；800ms 超时弃本轮（kTimeout）；流式语义对齐 ai_assist.h（先若干 kDelta，后恰好一次终止）；`HubAuth`（/v1/auth register+token） |
| CLI + 提词器演示 | `Sources/contextctl/ContextCtl.swift` | `contextctl collect/log/breaker/suggest/hub-token/prompter` |
| 测试 | `Tests/ContextCoreTests/` | 11 用例：store 往返/导出/清空/滚动、熔断跨进程、安全输入、黑名单、剪贴板默认关、留存默认关、Null 流式语义、kind 枚举契约 |
| 脚本化演示 | `scripts/demo.sh` | 验收序列全链路（输出见 W9-REPORT §3） |

## 快速使用

```bash
swift build -c release && swift test          # 构建 + 测试
BIN=.build/release/contextctl

$BIN collect app                              # NSWorkspace frontmost 应用
$BIN collect inject --kind key_session --text-in "ni hao" --text-out "你好"
$BIN log list --limit 10                      # 可查
$BIN log export --format jsonl > events.jsonl # 可导
$BIN log clear                                # 可一键清空
$BIN breaker trip|reset|status                # 熔断开关
$BIN hub-token --username u --password p      # 取 Hub Bearer
$BIN suggest --backend hub --token $TOKEN --text "今天开会"   # SSE 流式
$BIN suggest --backend null --text "断网了"                  # 离线兜底
$BIN prompter --backend hub --token $TOKEN --from-voice      # 提词器演示
bash scripts/demo.sh 2>&1 | tee .demo/demo-output.txt        # 验收全链路
```

数据文件默认 `~/Library/Application Support/mine-input/interaction.db`（技术方案 §3 数据层），
可用 `--db` / `MINE_INTERACTION_DB` 覆盖（demo 用 `context/.demo/interaction.db`）。

## 提词器行协议（prompter）

- `<文本>`：转写/上下文增量输入 → 触发一轮 suggest 流式刷新（面板实时追加 Δ 帧）；
- `\t`（真实 Tab 键产生的行）/ `tab` / `/tab`：**Tab 采纳**当前（或选中）候选——只建议不上屏，采纳才入库（kind=suggestion_feedback, taken=1）；
- `/1..9`：选中候选；`/q` 或 EOF：退出。

## ⌥Esc 感应点（文档化，W7 接线用）

FR5 三唤起的触发点与本模块的对应关系：

| # | 唤起（FR5） | 感应点（IME 侧，W1/W7 落地） | 本模块对应 |
|---|---|---|---|
| 1 | 随打即出（智能候选单独一组，异步补位） | Squirrel 候选链按键/组字回调（W7 已挂 W3 SPI） | `C0Collector.recordKeySession`（suggestion_shown/taken）+ `suggest`（kDelta） |
| 2 | **⌥Esc 流式面板** | **IME 热键 ⌥Esc（KeyChord 感应点）→ 唤起浮层/面板**；面板取 C0 上下文（preedit+text_before）发起 suggest 流式会话；Esc/点击外部关闭 | `prompter` 演示即此面板的终端形态（⌥Esc 触发等价于启动 `prompter`，输入行=上下文增量） |
| 3 | 语音实时提词（转写 300–500ms 增量刷新） | PTT 转写增量回调（W2 管线每段落定即触发，防抖 300–500ms） | `prompter --from-voice`（每行=一个转写增量，增量入库 kind=voice_session） |

接线约定（W7）：⌥Esc 由 Squirrel/IMK 侧注册（macos/ 目录，W9 不越界写）；触发后调
`SuggestRound`/`SuggestBackend.suggest`（或直接复用 `prompter` 进程作为浮层宿主）；
采纳（Tab/数字/点按）→ 写回客户端 + `C0Collector.recordSuggestionFeedback(shown:taken:1)`。
「只建议不上屏、不抢焦点」由面板语义保证：未采纳前绝不 commit。

## 隐私红线（FR4/FR8，本模块的硬约束）

1. **C0 仅**：输入框上下文（text_in/text_out）、应用名（app_id，NSWorkspace）、输入历史；
   `ocr_digest/asr_digest`（C1）默认 NULL，本 MVP 不采集；
2. **剪贴板采集默认关**：`clipboardCollectionEnabled=false`；必须
   `enableClipboardCollection(explicitConfirm: true)` 显式开启；开启后也只记摘要+长度，绝不记内容；
3. **上屏文本留存默认关**（L3）：不带 `--commit-retention` / `commitTextRetention=false` 时 text_out 恒为空；
4. **安全输入（密码框/支付）自动暂停不可关**：`secureInput=true` 一律拒收；
5. **敏感应用黑名单**命中即拒收；
6. **一键熔断**：`breaker trip` 后一切入库立即被拒（日志保留不新增），状态可查；
7. **可查可导可一键清空** + 30 天滚动（`log prune`）。

## W12 扩展（macos/w12，C1 采集）

W12（macos/w12/src/W12C1Collector.swift）在 C0 之上接通 C1：屏幕快照→Vision OCR→`ocr_digest`、
音频→W2 管线→`asr_digest`（**仅摘要/长度**，`sha256:… len:… lines:…`，绝不落原文/原图），
仅输入时触发（PTT 期间 + 按键触发窗）+ 防抖 2s；C1 默认关（`W12Privacy.enableC1(explicitConfirm:)`
显式开启，与本模块剪贴板开关同构）；密码框（`IsSecureEventInputEnabled`）自动停不可关；
黑名单跳过、熔断立即停沿用本模块既有门禁。`C0Collector.recordC1Sample(kind:ocrDigest:asrDigest:)`
为新增入库 API（additive）。⌥Esc 提词浮层（NSPanel）已由 W12 在 Squirrel 侧落地（见 macos/W12-REPORT.md）。
