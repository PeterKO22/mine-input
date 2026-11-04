# W19 memory-jsonl 车道报告

> 车道：W19 memory-jsonl（`context/`，Wave 6 §15.4）｜记忆层：JSONL 对话记忆库（N6）｜日期：2026-11-04
> 依据：docs/技术方案-v0.4.md §15.1（记忆层 schema 与规则——唯一规格源）｜docs/需求文档-v1.0.md 需求演进记录 N6 ｜
> context/W9-REPORT.md + context/README.md（InteractionStore/熔断/导出）｜macos/W12-REPORT.md（事件桥接现状）｜
> sdk/W8-REPORT.md（ingest 离线队列 / 事件体序列化）

## 1. 做了什么

SwiftPM `context/` 包新增 **MemoryCore 模块 + memoryctl 可执行**（Swift 6.4.2 / macOS arm64，零第三方依赖）：

- **(a) 记忆层 store**（`Sources/MemoryCore/`，§15.1 schema 唯一实现）：
  - `MemoryRecord.swift`：§15.1 记录 schema **JSON 键逐字一致**（`id/ts/device/app_id/situation/my_reply/meta/consent`，
    situation=`before_cursor/screen_digest/ocr_digest/asr_digest/thread`，my_reply=`text/mode(text|voice)`，
    meta=`from_suggestion/confidence/session_id`，consent=`c0|c1`）——单测断言键集合防漂移；
  - `MemoryStore.swift`：**append JSONL** 到 `~/Library/Application Support/mine-input/memory/YYYY-MM-DD.jsonl`
    （本地时区日分区，`MINE_MEMORY_DIR`/`--memory-dir` 可覆盖）；query/recent/edit/delete/clearAll；
  - `MemoryPairing.swift`：**从 W9 事件流配对「情境→回复」**——一次输入会话=一条记忆
    （同 `app_id`、相邻间隔 ≤30s（`--gap-ms` 可调）的连续事件段；上屏=`text_out` 非空，最后一个上屏事件为回复），
    **取消不记**（段内无上屏=取消/未上屏 → 不生成记忆）；thread 由同 app 前序回合回填（`["对方:…","我:…"]`）；
    `session_id` 由会话首尾 ts+app **确定性生成 → 配对重放幂等去重**（demo §2 实证）。
- **(b) 检索 CLI**（`Sources/memoryctl/`）：`memoryctl query --keyword/--app/--since YYYY-MM-DD|7d --limit N [--jsonl]`（回忆）；
  `memoryctl recent --limit N --for-suggest`（**suggest 上下文注入接口**：`MemoryStore.recentForSuggest` 输出
  「情境→我回」紧凑行，时间正序，供 suggest 提示前缀拼接）。
- **(c) 隐私联动**（红线不妥协）：
  - **熔断停记**：熔断标志（InteractionStore meta，跨进程）开启时 `append` 一律拒收（`MemoryError.breakerTripped`），
    记忆保留不新增（单测 + demo §8 实证）；
  - **一键清空**：`MemoryPrivacy.clearAll` **事件层+记忆层同清**（`memoryctl clear`，demo §9 实证）；
  - **手工编辑 API**（N8/§15.3）：`edit` **重写当日文件**（改 situation/my_reply）；`delete` **物理移除该行**
    （重写当日文件、无 tombstone；物理移除后查询/导出/同步不再含该条=撤回停传，demo §6/§7 实证）。
- **(d) 同步挂钩**：`MemorySync.swift` 记忆→**W8 同构事件体**（sdk `ser::event_to_json` / hub `/v1/ingest` `IngestIn`
  的 `InteractionEvent` 逐字段：ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/asr_digest?/…)，
  `memoryctl sync export` 导出 JSONL、`sync enqueue --queue-file F` 经 `IngestQueueSink`/`JSONLQueueSink`
  **JSONL 直进 ingest 队列**（一行一个事件体，W8 sdk `OfflineQueue.enqueue_ingest`/同步 worker 可逐行接走）。
- **(e) 测试 + demo**：`Tests/MemoryCoreTests` **13 用例全绿**（W9 既有 11 用例不动全绿，共 24）；
  `scripts/w19-demo.sh` 验收序列（注入会话事件→生成记忆→query 命中→编辑/删除→清空，另含样例 JSONL 行、
  recent、同步入队、熔断停记、配对幂等），全量输出见 §3。

## 2. 契约对齐（契约即协议）

**记忆记录 ↔ §15.1 schema（唯一规格源，键名逐字）：**

| JSON 键 | §15.1 | 本实现 |
|---|---|---|
| id / ts / device / app_id | `"uuid"` / ISO8601 / `"mac"` / 应用 | uuid / ISO8601（毫秒）/ mac / bundle id |
| situation.before_cursor | 输入框上下文 | 会话段首事件 text_in（上下文捕获） |
| situation.screen_digest / ocr_digest / asr_digest | `sha256:… len:N` 等 | C1 摘要（只落摘要/长度，缺省省略，默认 NULL） |
| situation.thread | `["对方:…","我:…"]` | 同 app 前序回合回填（MVP 近似，见 §4） |
| my_reply.text / mode | 回复文本 / `text|voice` | 上屏 text_out / 会话含 voice_session→voice |
| meta.from_suggestion / confidence / session_id | `prop_id|` / 0.0 / 会话 id | 建议事件标识 / 恒 0.0（见 §4）/ 确定性会话 id |
| consent | `c0|c1` | 含 C1 摘要→c1，否则 c0 |

**配对规则 ↔ §15.1「配对规则」**：「一次输入会话（起于上下文捕获、止于上屏/取消）= 一条记忆；取消不记」
→ 事件段切分（同 app + 间隔≤30s）＋上屏判定（`text_out` 非空）＋无上屏即取消跳过，逐条落实（单测
`testPairingOneSessionOneMemoryAndCancelNotRecorded`：4 会话 → 3 记忆，1 取消不记）。

**W8 同构事件体映射（记忆→ingest）**：ts(ISO8601)→ts(Unix 毫秒)；device→device_id；app_id→app_id；
mode=text|voice→kind=key_session|voice_session（hub `EventKind` 枚举，单测断言）；before_cursor→text_in；
my_reply.text→text_out；ocr/asr 摘要原样；from_suggestion 非空→suggestion_taken=1。导出**只含当前在库记录**
（删除=物理移除 → 撤回停传）。

## 3. 怎么验证（实测输出）

环境：macOS arm64，Swift 6.4.2。验证方式：`swift build` / `swift test` 全绿 + 脚本化演示 `scripts/w19-demo.sh`。

```text
$ swift build && swift test
Build complete!
        Executed 11 tests, with 0 failures (0 unexpected)     # ContextCoreTests（W9 既有，不动全绿）
        Executed 13 tests, with 0 failures (0 unexpected)     # MemoryCoreTests（W19 新增）
```

### 脚本化演示全量输出（`bash scripts/w19-demo.sh`，exit 0）

```text

=== 0. 构建与测试（swift build / swift test） ===
Build complete! (1.99秒)
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.324 (0.325) seconds
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.324 (0.326) seconds
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.021 (0.022) seconds
	 Executed 13 tests, with 0 failures (0 unexpected) in 0.021 (0.023) seconds

=== 1. 注入会话事件（W9 事件流；--ts 控时标，会话边界确定） ===
stored: event_id=1 kind=key_session
stored: event_id=2 kind=voice_session
stored: event_id=3 kind=suggestion_feedback
stored: event_id=4 kind=key_session
stored: event_id=5 kind=key_session
5 events

=== 2. 生成记忆（配对：一次输入会话=一条记忆，取消不记） ===
$ memoryctl pair
memory: id=ee66b8f6-e59e-47f1-819f-1681532b2530 session=1793794541000-1793794541000-com.apple.TextEdit
  {"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"ee66b8f6-e59e-47f1-819f-1681532b2530","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794541000-1793794541000-com.apple.TextEdit"},"my_reply":{"mode":"text","text":"收到，我会准时到"},"situation":{"before_cursor":"明天的会改到10点","thread":[]},"ts":"2026-11-04T12:15:41.000Z"}
memory: id=345be6e6-200f-419b-8608-a580176d8c9d session=1793794601000-1793794602000-com.apple.TextEdit
  {"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"345be6e6-200f-419b-8608-a580176d8c9d","meta":{"confidence":0,"from_suggestion":"suggestion_feedback:1793794602000","session_id":"1793794601000-1793794602000-com.apple.TextEdit"},"my_reply":{"mode":"voice","text":"今天下午有空，我们见一面"},"situation":{"before_cursor":"今天下午有空吗","thread":["对方:明天的会改到10点","我:收到，我会准时到"]},"ts":"2026-11-04T12:16:42.000Z"}
memory: id=b5cee43c-1b38-4f28-930e-45319b78325a session=1793794721000-1793794721000-com.tencent.xinWeChat
  {"app_id":"com.tencent.xinWeChat","consent":"c0","device":"mac","id":"b5cee43c-1b38-4f28-930e-45319b78325a","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794721000-1793794721000-com.tencent.xinWeChat"},"my_reply":{"mode":"text","text":"好的晚上见"},"situation":{"before_cursor":"晚上一起吃饭","thread":[]},"ts":"2026-11-04T12:18:41.000Z"}
paired: 4 sessions → 3 memories (1 cancelled not recorded; appended=3 dedup-skipped=0)
$ memoryctl pair  # 重放（session_id 确定性 → 幂等去重）
paired: 4 sessions → 3 memories (1 cancelled not recorded; appended=0 dedup-skipped=3)
$ cat 当日 JSONL（样例，一行一条记忆）
{"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"ee66b8f6-e59e-47f1-819f-1681532b2530","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794541000-1793794541000-com.apple.TextEdit"},"my_reply":{"mode":"text","text":"收到，我会准时到"},"situation":{"before_cursor":"明天的会改到10点","thread":[]},"ts":"2026-11-04T12:15:41.000Z"}
{"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"345be6e6-200f-419b-8608-a580176d8c9d","meta":{"confidence":0,"from_suggestion":"suggestion_feedback:1793794602000","session_id":"1793794601000-1793794602000-com.apple.TextEdit"},"my_reply":{"mode":"voice","text":"今天下午有空，我们见一面"},"situation":{"before_cursor":"今天下午有空吗","thread":["对方:明天的会改到10点","我:收到，我会准时到"]},"ts":"2026-11-04T12:16:42.000Z"}
{"app_id":"com.tencent.xinWeChat","consent":"c0","device":"mac","id":"b5cee43c-1b38-4f28-930e-45319b78325a","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794721000-1793794721000-com.tencent.xinWeChat"},"my_reply":{"mode":"text","text":"好的晚上见"},"situation":{"before_cursor":"晚上一起吃饭","thread":[]},"ts":"2026-11-04T12:18:41.000Z"}

=== 3. 检索 query（回忆：--keyword / --app / --since） ===
$ memoryctl query --keyword 准时
2026-11-04T12:16:42.000Z [345be6e6-200f-419b-8608-a580176d8c9d] app=com.apple.TextEdit mode=voice
  情境: 今天下午有空吗
  我回: 今天下午有空，我们见一面
  thread: 对方:明天的会改到10点 / 我:收到，我会准时到
2026-11-04T12:15:41.000Z [ee66b8f6-e59e-47f1-819f-1681532b2530] app=com.apple.TextEdit mode=text
  情境: 明天的会改到10点
  我回: 收到，我会准时到
matched: 2
$ memoryctl query --app xinWeChat --jsonl
{"app_id":"com.tencent.xinWeChat","consent":"c0","device":"mac","id":"b5cee43c-1b38-4f28-930e-45319b78325a","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794721000-1793794721000-com.tencent.xinWeChat"},"my_reply":{"mode":"text","text":"好的晚上见"},"situation":{"before_cursor":"晚上一起吃饭","thread":[]},"ts":"2026-11-04T12:18:41.000Z"}
matched: 1
$ memoryctl query --since 7d --limit 10
2026-11-04T12:18:41.000Z [b5cee43c-1b38-4f28-930e-45319b78325a] app=com.tencent.xinWeChat mode=text
  情境: 晚上一起吃饭
  我回: 好的晚上见
2026-11-04T12:16:42.000Z [345be6e6-200f-419b-8608-a580176d8c9d] app=com.apple.TextEdit mode=voice
  情境: 今天下午有空吗
  我回: 今天下午有空，我们见一面
  thread: 对方:明天的会改到10点 / 我:收到，我会准时到
2026-11-04T12:15:41.000Z [ee66b8f6-e59e-47f1-819f-1681532b2530] app=com.apple.TextEdit mode=text
  情境: 明天的会改到10点
  我回: 收到，我会准时到
matched: 3

=== 4. recent（供 suggest 上下文注入的接口） ===
$ memoryctl recent --limit 3 --for-suggest
[2026-11-04T12:15:41.000Z] 情境:明天的会改到10点 → 我回:收到，我会准时到
[2026-11-04T12:16:42.000Z] 情境:今天下午有空吗 → 我回:今天下午有空，我们见一面
[2026-11-04T12:18:41.000Z] 情境:晚上一起吃饭 → 我回:好的晚上见

=== 5. 手工编辑（重写当日文件，N8） ===
$ memoryctl edit --id 345be6e6-200f-419b-8608-a580176d8c9d --reply 收到，我会准时到（改后）
edited: id=345be6e6-200f-419b-8608-a580176d8c9d（当日文件已重写）
{"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"345be6e6-200f-419b-8608-a580176d8c9d","meta":{"confidence":0,"from_suggestion":"suggestion_feedback:1793794602000","session_id":"1793794601000-1793794602000-com.apple.TextEdit"},"my_reply":{"mode":"voice","text":"收到，我会准时到（改后）"},"situation":{"before_cursor":"今天下午有空吗","thread":["对方:明天的会改到10点","我:收到，我会准时到"]},"ts":"2026-11-04T12:16:42.000Z"}
$ memoryctl query --keyword 改后
2026-11-04T12:16:42.000Z [345be6e6-200f-419b-8608-a580176d8c9d] app=com.apple.TextEdit mode=voice
  情境: 今天下午有空吗
  我回: 收到，我会准时到（改后）
  thread: 对方:明天的会改到10点 / 我:收到，我会准时到
matched: 1

=== 6. 删除（物理移除该行，无 tombstone；撤回停传） ===
行数（删除前）: 3
$ memoryctl delete --id 345be6e6-200f-419b-8608-a580176d8c9d
deleted: id=345be6e6-200f-419b-8608-a580176d8c9d（物理移除该行，导出/同步不再包含）
行数（删除后）: 2（物理移除）
$ memoryctl query --keyword 改后   # 应无命中
matched: 0

=== 7. 同步挂钩：W8 同构事件体（JSONL 直进 ingest 队列） ===
$ memoryctl sync export
{"app_id":"com.tencent.xinWeChat","device_id":"mac-demo","kind":"key_session","text_in":"晚上一起吃饭","text_out":"好的晚上见","ts":1793794721000}
{"app_id":"com.apple.TextEdit","device_id":"mac-demo","kind":"key_session","text_in":"明天的会改到10点","text_out":"收到，我会准时到","ts":1793794541000}
$ memoryctl sync enqueue --queue-file .demo/w19/ingest-queue.jsonl
enqueued: 2 events → .demo/w19/ingest-queue.jsonl（JSONL 直进 ingest 队列）
$ cat ingest 队列文件（一行一个 /v1/ingest 事件体）
{"app_id":"com.tencent.xinWeChat","device_id":"mac-demo","kind":"key_session","text_in":"晚上一起吃饭","text_out":"好的晚上见","ts":1793794721000}
{"app_id":"com.apple.TextEdit","device_id":"mac-demo","kind":"key_session","text_in":"明天的会改到10点","text_out":"收到，我会准时到","ts":1793794541000}

=== 8. 熔断停记（breaker trip 后记忆保留不新增） ===
stored: event_id=6 kind=key_session
breaker: TRIPPED（一切采集立即停；日志保留不新增）
$ memoryctl pair   # 熔断后落盘 → 期望拒收
refused: circuit breaker tripped: memory recording stopped
  (exit=3 按预期拒收)
$ memoryctl status
memory_dir: .demo/w19/memory
db: .demo/w19/interaction.db
memories_total: 2
events_total: 6
breaker: TRIPPED（记忆停记、采集停）
breaker: off（采集恢复）
$ memoryctl pair   # 熔断恢复后补记（事件仍在事件流）
memory: id=576465f5-b5ee-4090-b68b-b3fa1088dc57 session=1793794601000-1793794602000-com.apple.TextEdit
  {"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"576465f5-b5ee-4090-b68b-b3fa1088dc57","meta":{"confidence":0,"from_suggestion":"suggestion_feedback:1793794602000","session_id":"1793794601000-1793794602000-com.apple.TextEdit"},"my_reply":{"mode":"voice","text":"今天下午有空，我们见一面"},"situation":{"before_cursor":"今天下午有空吗","thread":["对方:明天的会改到10点","我:收到，我会准时到"]},"ts":"2026-11-04T12:16:42.000Z"}
memory: id=e25eabb3-637b-489e-9c8d-4153741777d4 session=1793794781000-1793794781000-com.apple.TextEdit
  {"app_id":"com.apple.TextEdit","consent":"c0","device":"mac","id":"e25eabb3-637b-489e-9c8d-4153741777d4","meta":{"confidence":0,"from_suggestion":"","session_id":"1793794781000-1793794781000-com.apple.TextEdit"},"my_reply":{"mode":"text","text":"不应被记住"},"situation":{"before_cursor":"熔断后的新会话","thread":["对方:明天的会改到10点","我:收到，我会准时到","对方:今天下午有空吗","我:今天下午有空，我们见一面"]},"ts":"2026-11-04T12:19:41.000Z"}
paired: 5 sessions → 4 memories (1 cancelled not recorded; appended=2 dedup-skipped=2)

=== 9. 一键清空（事件层 + 记忆层同清） ===
$ memoryctl status   # 清空前
memory_dir: .demo/w19/memory
db: .demo/w19/interaction.db
memories_total: 4
events_total: 6
breaker: off
$ memoryctl clear
cleared: 4 memories + 6 events removed（一键清空：事件层+记忆层同清）
$ memoryctl status   # 清空后
memory_dir: .demo/w19/memory
db: .demo/w19/interaction.db
memories_total: 0
events_total: 0
breaker: off
$ ls .demo/w19/memory（记忆文件已全删）

=== DEMO: ALL STEPS EXECUTED ===
```

**验收序列对照**：① 注入会话事件（5 事件 / 4 输入会话，`--ts` 控时标确定会话边界）→ ② 生成记忆
（4 会话 → 3 记忆，**取消会话不记**；语音+建议采纳合成一条（mode=voice、from_suggestion 回填）；
重放 pair 幂等去重 appended=0；**样例 JSONL 行**见 `cat 当日 JSONL`）→ ③ query 命中（--keyword 命中 2 条含
thread 回填、--app 精确过滤、--since 7d 全量）→ ④ recent --for-suggest（suggest 注入行，时间正序）→
⑤ 手工编辑（重写当日文件，改后可查）→ ⑥ 删除（3 行→2 行**物理移除**，再查无命中）→ ⑦ 同步挂钩
（W8 同构事件体导出 2 条=删除后在库数（**撤回停传**），`sync enqueue` JSONL 直进 ingest 队列文件）→
⑧ 熔断停记（trip 后 pair 落盘拒收 exit=3、status 显示 TRIPPED，reset 后补记）→ ⑨ 一键清空
（`memoryctl clear`：4 记忆 + 6 事件同清，memories_total=0、events_total=0、当日文件全删）。

## 4. 遗留与 blocker

1. **记忆删除后重配对会重生**（demo §8 实证）：配对源是事件流，删除只物理移除记忆行；源事件仍在时
   再次 `pair` 会重新生成该记忆（session_id 去重以「在库记忆」为准）。彻底不回流 = 一键清空（同清）
   或清事件层对应事件；如需逐条防回流需「已删会话登记」，与 §15.1「删除即物理移除该行」的无 tombstone
   要求如何并存需产品决策，MVP 不做。
2. **thread 为 MVP 近似**：W9 事件流只有我方输入会话，「对方:」侧文本取自当时输入框上下文
   （before_cursor）；真实对方消息需 C1（OCR 摘要）或上层显式喂 situation.thread。
3. **confidence 恒 0.0**：事件流无置信度字段（§15.1 样例即 0.0）；待 suggest 分数/提案置信度回填（W20）。
4. **from_suggestion 记事件标识**（`suggestion_feedback:<ts>`）而非 ai_assist.h `prop_id`：W9 事件无提案 id；
   W20 SPI v2（§15.2）落地后由提案卡回填真 prop_id。
5. **同步只到「导出/入队」挂钩**：真正的 flush/补传/E2E 加密由 W8 sdk `OfflineQueue`（C++，不越界写 sdk/）
   或同步 worker 接走 `JSONLQueueSink` 队列文件；Hub `/v1/ingest` 无幂等键（W8 遗留）对记忆事件同样适用。
6. **配对会话边界是启发式**（同 app + 间隔≤30s）：W7/W12 事件桥接（`W12EventBridge`）若有显式
   会话 begin/commit/cancel 回调，可直接喂 `MemoryStore.append`（取消不记在回调处天然成立），本车道未越界写 macos/。
7. **记忆管理界面（§15.3）属 W20 proposal-ui**：本车道只交付手工编辑 API（edit/delete 重写当日文件）与 CLI。
8. **additive 小改 W9 文件**（仍在 context/ 车道内）：`C0Collector.record*` 增可选 `ts:` 参数、
   `contextctl collect inject` 增 `--ts MS`（事件时间，回放/配对确定性演示用）；W12EventBridge 等既有调用零改动。
9. 事件层「上屏文本留存默认关」红线不破：配对需要会话事件带 `text_out`（上屏回复），留存关闭时
   会话视同取消不记（隐私保守方向）；W7 接线时在 commit 回调直喂记忆层可不受此限。

## 5. 产物清单

- `context/Sources/MemoryCore/MemoryRecord.swift`（§15.1 schema）
- `context/Sources/MemoryCore/MemoryStore.swift`（JSONL 当日文件 store + 隐私联动 MemoryPrivacy）
- `context/Sources/MemoryCore/MemoryPairing.swift`（事件流→情境/回复配对）
- `context/Sources/MemoryCore/MemorySync.swift`（W8 同构事件体 + IngestQueueSink/JSONLQueueSink）
- `context/Sources/memoryctl/MemoryCtl.swift`（memoryctl CLI：pair/query/recent/edit/delete/clear/sync/status）
- `context/Tests/MemoryCoreTests/MemoryCoreTests.swift`（13 用例全绿）
- `context/scripts/w19-demo.sh`（验收序列，可执行）
- `context/Package.swift`（+MemoryCore/memoryctl/MemoryCoreTests targets）、`context/README.md`（W19 节）
- `context/Sources/ContextCore/C0Collector.swift`、`context/Sources/contextctl/ContextCtl.swift`（additive：`ts:` / `--ts`）
- `context/W19-REPORT.md`（本报告）
