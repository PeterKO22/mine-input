# W29-REPORT — 回复留存（L3）产品化：让记忆层真正能攒「情境→回复」

> 日期：2026-11-08 ｜ 范围：context/、macos/w12/、macos/w20/、SECURITY*.md、docs/平价表 ｜ 提交前缀 `W29: `
> 需求（用户原话）：「用 jsonl 格式记录『在什么情况下，我回了什么话』，以后帮我回忆，也可以直接提示。当然还要有界面可以由我手工调整」。

## 0. 根因（沿用已查明结论，不重查）

事件层与配对逻辑本来正常，但 **text_out 落库被清空**：W9 设计的「上屏文本留存(L3) 默认关」
只有运行时标志（`W12Config.Settings.commitTextRetention` / `w12ctl --commit-retention`），
**未持久化、无用户开关**——生产 W12EventBridge 的 C0Collector 恒默认关 → 每次 commit 的
`text_out` 落库为空 → `memoryctl pair` 把这些段全数计成误导性的「928 cancelled」→ 记忆层永空。

## 1. 改动总览

### (1) 持久化（仿 `c1_enabled` 模式，跨进程生效，默认关）

- `context/Sources/ContextCore` 不动语义；`macos/w12/src/W12Config.swift`（W12Privacy）新增：
  - `enableCommitTextRetention(store:explicitConfirm:)`（不显式确认拒绝开启）/
    `disableCommitTextRetention(store:)` / `isCommitTextRetentionEnabled(store:)`；
  - 持久键 **`commit_text_retention`**（InteractionStore meta，与 `c1_enabled` 同款，跨进程）。
- `macos/w12/src/W12EventBridge.swift`：每次上报 `syncRetentionGate()` **现读持久值**决定
  text_out 留存/清空（reportKeySession / reportVoiceSession / reportCandidatePick /
  reportSuggestionFeedback 全走）；`commitRetentionOverride`（探针/测试直通，生产恒 nil）；
  report* 增 `ts:` 注入参（伪时钟，缺省 Date() 不变）。**密码框/安全输入（secureInput）
  恒拒收不变**（拒收即零入库，与留存开关无关）。

### (2) 用户开关（可开、可查、可调）

- **⌥M 管理浮层**（`macos/w20/src/W20MemoryPanel.swift`）顶部新增第二行
  **「记录我的回复（用于记忆与推荐）」**开关 + 状态行（W20RetentionControl 抽象，
  `macos/w20/src/W20MemoryStore.swift`）；**首开弹显式确认**（五项说清才可开：
  留存什么 / 干嘛用 / 本地存储 / 随时可关 / 清空连事件一起 = `W12Privacy.retentionConsentText`），
  取消即拨回、绝不静默留存；关闭后新事件不再留存。
- 生产实现 `W20SquirrelRetentionControl`（`macos/w20/src/W20SquirrelGlue.swift`）与采集链路
  **同源 W12Privacy 持久 meta**（跨进程：w12ctl 开、IME 立即生效，反之亦然）。
- `w12ctl privacy retain on|off`：**on 需 `--confirm` 防误触**（缺参 exit 2 并提示）；
  `privacy status` 如实显示持久开关（原行显示惰性 Settings 字段，已改为 meta 真值）。
- 既有可调面不变：⌥M 时间线单条 situation/my_reply 查看/编辑/删除/导出（N8 手工调整）。

### (3) 误导修复（memoryctl pair 输出）

- `context/Sources/MemoryCore/MemoryPairing.swift`：`Options.retentionEnabled`（memoryctl 从
  meta 注入）+ `Outcome.noRetainedReplyCount`，与 `cancelledCount` **分开计数**：
  - 留存**开**（默认，W19 既有语义）：text_out 全空段 = **真取消**；
  - 留存**关**：全空段归 **「段内无留存回复」**——text_out 是唯一上屏标记、被留存开关抹掉，
    与真取消不可分辨，如实单列不冒充；
- `context/Sources/memoryctl/MemoryCtl.swift` 输出：
  `paired: N sessions → M memories (段内无留存回复 X · 真取消 Y not recorded; …)`，
  且 X>0 且留存未开时打提示 **「回复留存未开，开后新会话才会配对（开启：⌥M…或 w12ctl privacy retain on --confirm）」**
  （`MemoryPairing.noRetainedReplyHint` 单一事实源）。

### (4) 文档

- `SECURITY.md` / `SECURITY.zh-CN.md` §3 数据分类表相关行：
  - 按键/候选事件行：回复文本（text_out）**仅在留存开关开启时留存**（首开显式确认、**默认关**、关=永不落库）；
  - JSONL 记忆库行：my_reply 配对仅在留存开启期间产生（⌥M 可开、默认关；一键清空事件层+记忆层同清）。
- `docs/平价表-macos-android.md`：行 #10（回复留存（L3）与「情境→回复」记忆）+ **TODO-G**
  （Android 版：同隐私门——首开确认/默认关/密码框恒拒/清空联动/不进同步导出）。

## 2. 验收（全部实测，构建树只编译不 launch）

| 项 | 命令 | 结果 |
|---|---|---|
| 单测 · context（37 既有 + 3 新） | `cd context && swift test` | **40/40 全绿**（W29PairingRetentionTests 3：分开计数/计数之和=会话总数/提示语逐字） |
| 单测 · w12（16 既有 + 4 新） | `cd macos/w12 && swift test` | **20/20 全绿**（W29RetentionTests 4：开关持久化跨实例/留存开关与桥闸/override/密码框拒收） |
| 单测 · w20 无回归 | `cd macos/w20 && swift test` | **15/15 全绿** |
| 单测 · w7 无回归 | `bash build/w7-test-ptt-lock.sh` | **56/56 ALL PASS**（伪时钟，零 sleep） |
| 探针实证 · W29 全链路 | `bash macos/w12/scripts/w29-probe.sh` | **26/26 ALL GREEN**（见 §3） |
| 探针回归 · W27 | `w12ctl w27-e2e` | **ALL PASS**（23/23，桥改动无回归） |
| 界面形态回归 | `bash macos/w20/scripts/w20-demo.sh` | **ALL GREEN**（29，含 swift test 15/15 + panel-dump） |
| 全 app 目标编译 | `xcodebuild -project Squirrel.xcodeproj -configuration Release -scheme Squirrel build` | **BUILD SUCCEEDED**（未 launch；W20SquirrelRetentionControl/面板/桥均过编译） |

新单测伪时钟口径：事件 ts 全部显式注入（固定毫秒值），全文零 Thread.sleep。

## 3. 探针实证输出（w29-probe.sh 关键行，确定性：ts 注入伪时钟、独立库、零 sleep/零 TCC/零 launch）

```
== [1/7] 关留存 → 注入 commit 事件 → text_out 空 ==
  [PASS] 关留存 → interaction.db text_out 空（quote=''）
== [2/7] privacy retain on --confirm（防误触）→ 注入 commit 事件 → text_out 非空 ==
  [PASS] retain on 无 --confirm 拒绝（防误触）
  [PASS] 持久开关跨进程可见（privacy status）
  [PASS] 开留存 → interaction.db text_out 非空行（收到，我会准时到）
== [3/7] memoryctl pair → JSONL 记忆条目（situation + my_reply）==
    | {"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"…",
    |  "meta":{"confidence":0,"from_suggestion":"","session_id":"1793731033000-…"},
    |  "my_reply":{"mode":"text","text":"收到，我会准时到"},
    |  "situation":{"before_cursor":"明天的会改到10点","thread":[]},"ts":"2026-11-03T18:37:13.000Z"}
    | paired: 2 sessions → 1 memories (段内无留存回复 0 · 真取消 1 not recorded; appended=1 dedup-skipped=0)
  [PASS] 记忆条目含 situation / my_reply（JSONL 已落盘当日文件）
== [4/7] 密码框（secure input）→ 拒收恒不变（留存开着也拒）==
  [PASS] 密码框拒收原因  [PASS] 密码框零入库（count 2 不变）
== [5/7] 关留存 → 新事件 text_out 空（既有留存不回改）==
  [PASS] 关留存 → 新事件 text_out 空  [PASS] 既有留存不回改（可查可删）
== [6/7] memoryctl pair：「段内无留存回复」与「真取消」分开计数 + 提示 ==
    | paired: 3 sessions → 1 memories (段内无留存回复 2 · 真取消 0 not recorded; appended=0 dedup-skipped=1)
    | 提示：回复留存未开，开后新会话才会配对（开启：⌥M「记录我的回复（用于记忆与推荐）」或 w12ctl privacy retain on --confirm）
== [7/7] ⌥M 管理浮层界面形态（记录我的回复开关在场）==
  [PASS] 开关标题「记录我的回复（用于记忆与推荐）」

PASS=26 FAIL=0  W29-PROBE ALL GREEN
```

## 4. 隐私契约（逐条对表，全部保持）

| 契约 | 落法 |
|---|---|
| L3 显式确认后才留存 | `enableCommitTextRetention(explicitConfirm:)` 不确认拒绝；⌥M 首开弹五项确认文案、取消拨回；w12ctl `retain on` 需 `--confirm` |
| 密码框/安全输入恒拒收 | secureInput → `refused(.secureInputPaused)` 零入库，与留存开关无关（单测 + 探针双证） |
| 熔断/一键清空联动 | 熔断停记不变；`memoryctl clear` 事件层+记忆层同清不变（既有单测守住）；确认文案明示「清空连事件一起」 |
| 本地存储、不进同步导出、无遥测 | text_out 只进本地 interaction.db；记忆 JSONL 的 `screen_text` 仍不进同步/ingest 导出（W27 门不变）；无任何新增网络面 |
| 默认关 | meta 无值即关；`privacy status`/⌥M 状态行如实显示 |

## 5. 语义说明与已知限制（如实标注）

1. **归类规则**：留存开 → text_out 全空段=真取消（W19 既有语义，既有 37 项 context 测试零改动零回归）；
   留存关 → 全空段=「段内无留存回复」。留存关时两者**客观不可分辨**（text_out 是事件流里唯一的
   上屏标记，被留存开关抹掉），故如实归「无留存回复」并提示——不再把它们冒充「真取消」。
2. **既有留存不回改**：关闭开关只影响新事件；旧 text_out 留存仍可查/可改/可删/一键清空。
   开后**新会话**才会配对出 my_reply（提示语已明示）。
3. `W12Settings.commitTextRetention` 保留为探针直通字段（接 `commitRetentionOverride`）；
   生产唯一事实源 = meta 持久开关（文档已注明）。
4. **真机 IME 人工验收留待装机**：⌥M 弹窗手感、开关状态实时刷新在真机 Squirrel-dev.app 验；
   构建树 Squirrel.app **未 launch**（W27 §9.5 红线：TCC cdhash 漂移弹窗骚扰实锤）。
   w29-probe/w27-e2e/单测均零 launch、零 TCC。

## 6. 文件清单

| 文件 | 动作 |
|---|---|
| `context/Sources/MemoryCore/MemoryPairing.swift` | 分开计数（Options.retentionEnabled / Outcome.noRetainedReplyCount）+ 提示语常量 |
| `context/Sources/memoryctl/MemoryCtl.swift` | meta 注入 + 分项输出 + 提示 |
| `macos/w12/src/W12Config.swift` | W12Privacy 留存开关（meta `commit_text_retention`）+ 五项确认文案 |
| `macos/w12/src/W12EventBridge.swift` | 按持久值留留存闸 + override + ts 注入参 |
| `macos/w12/tools/w12ctl/main.swift` | `privacy retain on --confirm|off`、status 如实化、`bridge commit|voice` 注入 |
| `macos/w12/tests/W12CoreTests/W29RetentionTests.swift` | 新增 4 项单测（伪时钟 ts 注入） |
| `macos/w20/src/W20MemoryStore.swift` | W20RetentionControl 抽象 |
| `macos/w20/src/W20MemoryPanel.swift` | ⌥M「记录我的回复（用于记忆与推荐）」开关 + 首开确认弹窗 |
| `macos/w20/src/W20SquirrelGlue.swift` | W20SquirrelRetentionControl（W12Privacy meta 同源） |
| `macos/w20/tools/w20ctl/main.swift` | panel-dump 留存开关桩（界面形态可验） |
| `context/Tests/MemoryCoreTests/W29PairingRetentionTests.swift` | 新增 3 项单测 |
| `macos/w12/scripts/w29-probe.sh` | 端到端探针（26 项断言） |
| `SECURITY.md` / `SECURITY.zh-CN.md` | 数据分类表相关行（留存开关可开、默认关） |
| `docs/平价表-macos-android.md` | 行 #10 + TODO-G |
| `macos/W29-REPORT.md` | 本报告 |
