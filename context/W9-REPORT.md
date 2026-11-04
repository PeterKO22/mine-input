# W9 context 车道报告

> 车道：W9 context（`context/` 目录）｜M5 前置：上下文引擎 MVP + 交互日志 + 动态提词器演示（C0 级）｜日期：2026-11-04
> 依据：docs/开发任务计划.md W9 规格 + §3 工作约定 ｜ docs/技术方案-v0.4.md §8（上下文引擎/提词器） ｜ docs/需求文档-v1.0.md FR4/FR5 ｜ ai/spi/ai_assist.h（suggest/ingest/InteractionEvent 契约） ｜ hub/W4-REPORT.md（/v1/suggest SSE、/v1/ingest）

## 1. 做了什么

SwiftPM 包（`context/`，Swift 6.4.2 / macOS arm64，零第三方依赖，仅 libsqlite3/AppKit/Foundation），只写本车道目录：

- **(a) 交互日志 store**（`Sources/ContextCore/InteractionStore.swift`）：本地 SQLite `events` 表**逐字段对齐技术方案 §8.2 InteractionEvent**（`ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/asr_digest?/keystroke_cadence/suggestion_shown/suggestion_taken`，与 hub `IngestIn` 同名同义），`ts` 建索引（时间索引事件流）；**可查**（`log list/count`，按 kind/时间窗过滤）、**可导**（JSONL/CSV，snake_case 与 hub 事件体同构）、**可一键清空**（`log clear`，meta 保留）、**30 天滚动**（`log prune --days 30`，§8.2 默认 30 天）。
- **(b) C0 采集器**（`Sources/ContextCore/C0Collector.swift`）：frontmost 应用名（**NSWorkspace** `frontmostApplication`）；**输入会话事件入库 API**（`recordKeySession/recordVoiceSession/recordCandidatePick/recordSuggestionFeedback`——供 W7 后续上报，kind 枚举与 hub `EventKind` 一致）；安全输入（密码框/支付）**自动暂停不可关**（拒收）；敏感应用黑名单命中拒收；上屏文本留存默认关（L3）；**剪贴板采集默认关**，必须 `enableClipboardCollection(explicitConfirm:)` 显式开启，且开启后**只记摘要+长度，绝不记内容**（隐私红线）。
- **(c) 熔断开关**（`Sources/ContextCore/CircuitBreaker.swift`）：全局标志（持久于 store `meta` 表，**跨进程生效**）；`trip()` 后一切采集立即停（collector 早停 + store.insert 兜底拒绝），**日志保留不新增**；`reset()` 显式恢复。
- **(d) suggest 客户端**（`Sources/ContextCore/SuggestClient.swift`）：`HubSuggestBackend` 调 **Hub `/v1/suggest` SSE**（`event: suggestion` 帧→kDelta、`event: done`→kDone，Bearer 鉴权，`HubAuth` 走 /v1/auth register+token）；**Null 后端离线兜底**（`NullSuggestBackend`）；**800ms 超时弃本轮**（kTimeout，NFR3）；流式语义对齐 ai_assist.h：先若干 kDelta、后**恰好一次**终止、终止后更新丢弃。
- **(e) 提词器 TUI/浮层演示**（`contextctl prompter`）：**⌥Esc 感应点文档化**（README「⌥Esc 感应点」表：三唤起 × IME 侧感应点 × 本模块对应，供 W7 接线）；**终端流式面板**：转写/上下文增量输入（每行一轮）→ 建议实时刷新（Δ 帧带毫秒时标）→ **Tab 采纳**（`\t`/`tab`/`/tab`，只建议不上屏，采纳才入库 kind=suggestion_feedback taken=1）；`/1-9` 选中、`/q` 退出；`--from-voice` 走语音 300–500ms 增量刷新语义。
- 配套：`contextctl` CLI（collect/log/breaker/suggest/hub-token/prompter）、`Tests/ContextCoreTests` 11 用例、`scripts/demo.sh` 脚本化演示、`README.md`。

## 2. 契约对齐（契约即协议）

**交互日志表列 ↔ §8.2 InteractionEvent ↔ hub `/v1/ingest` ↔ ai/spi/ai_assist.h：**

| events 表列 | §8.2 / hub IngestIn | ai_assist.h InteractionEvent 映射 |
|---|---|---|
| ts（索引） | ts（Unix 毫秒） | timestamp_ms |
| device_id / app_id | device_id / app_id | fields（app_id；C1 语义） |
| kind（CHECK 枚举） | kind = key_session/voice_session/candidate_pick/suggestion_feedback | type（kCommit/kSuggestionShown/kSuggestionAdopted/kSuggestionDismissed/kCorrectionApplied 语义并入 kind+text 字段） |
| text_in / text_out | text_in / text_out | text（上屏文本留存默认关） |
| ocr_digest / asr_digest（默认 NULL） | ocr_digest? / asr_digest? | fields（C1，仅显式开启） |
| keystroke_cadence / suggestion_shown / suggestion_taken | 同名 | fields（suggestion_taken ↔ kSuggestionAdopted） |

**suggest 流式**：`SuggestContext{before_cursor/app_id/from_voice/context_digest}` ↔ hub `SuggestIn` ↔ ai_assist.h `AiContext`（C0 窗口）；`Candidate{text/score/source}` ↔ hub SSE 帧 ↔ ai_assist.h `Candidate`；`StreamStatus{kDelta/kDone/kError/kTimeout}` ↔ ai_assist.h 同名枚举。kind 枚举字面值已由单测断言与 hub `EventKind` 一致。

## 3. 怎么验证（实测输出）

环境：macOS arm64，Swift 6.4.2；Hub 本地容器 **localhost:8088**（W4 产物，healthz ok）。验证方式：`swift build` / `swift test` 全绿 + **脚本化演示 `scripts/demo.sh`**（注入会话事件→日志入库→sqlite3 查询输出→suggest 流式刷新→熔断后停止入库，另含剪贴板默认关/可导/可清）。

```text
$ swift build && swift test
Build complete!
	 Executed 11 tests, with 0 failures (0 unexpected)
```

### 脚本化演示全量输出（`bash scripts/demo.sh`，exit 0）

```text

=== 0. 构建与测试（swift build / swift test） ===
Build complete! (0.94秒)
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.306 (0.308) seconds

=== 1. C0 采集器：frontmost 应用（NSWorkspace）+ 采集状态 ===
store ready: .demo/interaction.db
device_id=mac-you breaker=off
frontmost_app: loginwindow
frontmost_app_id: com.apple.loginwindow
db: .demo/interaction.db
device_id: mac-you
frontmost_app: loginwindow (com.apple.loginwindow)
breaker: off
clipboard_collection: OFF（默认关）
commit_text_retention: off（默认关）
events_total: 0

=== 2. 输入会话事件入库 API（C0Collector.record*，供 W7 上报） ===
stored: event_id=1 kind=key_session
stored: event_id=2 kind=key_session
stored: event_id=3 kind=voice_session
stored: event_id=4 kind=candidate_pick
stored: event_id=5 kind=suggestion_feedback
-- 负例 1：安全输入（密码框/支付）自动暂停不可关 → 期望拒收
refused: secure input: auto-paused (cannot be disabled)
  (exit=3 按预期拒绝)
-- 负例 2：敏感应用黑名单（keychain）→ 期望拒收
refused: exec failed: blacklisted app: com.apple.keychainaccess
  (exit=3 按预期拒绝)
-- 隐私默认：不带 --commit-retention 时上屏文本留存关闭（text_out 为空）
stored: event_id=6 kind=key_session
id   text_in    text_out
--  ----------  --------
 6  留存默认关

=== 3. 交互日志：sqlite3 查询输出（可查，时间索引） ===
$ sqlite3 .demo/interaction.db ".schema events"
CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    app_id TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL CHECK(kind IN
        ('key_session','voice_session','candidate_pick','suggestion_feedback')),
    text_in TEXT NOT NULL DEFAULT '',
    text_out TEXT NOT NULL DEFAULT '',
    ocr_digest TEXT,
    asr_digest TEXT,
    keystroke_cadence REAL,
    suggestion_shown INTEGER,
    suggestion_taken INTEGER
);
CREATE INDEX idx_events_ts ON events(ts);
$ sqlite3 -header -column .demo/interaction.db "SELECT ... FROM events ORDER BY id"
id       ts               kind                 app_id           text_in             text_out           cad  shown  taken
--  -------------  -------------------  ---------------------  ----------  --------------------------  ---  -----  -----
 1  1793730973174  key_session          com.apple.TextEdit     ni hao      你好                        3.2      2      1
 2  1793730973184  key_session          com.apple.TextEdit     shijie      世界                        3.1
 3  1793730973192  voice_session        com.apple.TextEdit     今天开会    今天开会。                           3      1
 4  1793730973201  candidate_pick       com.apple.TextEdit     zni         智能                        2.8
 5  1793730973209  suggestion_feedback  com.apple.loginwindow  今天开会    今天开会——好的，我稍后处理           3      1
 6  1793730973231  key_session          com.apple.loginwindow  留存默认关
$ sqlite3 .demo/interaction.db "SELECT COUNT(*) FROM events"
6

=== 4. 可导（JSONL / CSV） ===
$ contextctl log export --format jsonl
{"app_id":"com.apple.loginwindow","device_id":"mac-you","kind":"key_session","text_in":"留存默认关","text_out":"","ts":1793730973231}
{"app_id":"com.apple.loginwindow","device_id":"mac-you","kind":"suggestion_feedback","suggestion_shown":3,"suggestion_taken":1,"text_in":"今天开会","text_out":"今天开会——好的，我稍后处理","ts":1793730973209}
{"app_id":"com.apple.TextEdit","device_id":"mac-you","keystroke_cadence":2.8,"kind":"candidate_pick","text_in":"zni","text_out":"智能","ts":1793730973201}
{"app_id":"com.apple.TextEdit","device_id":"mac-you","kind":"voice_session","suggestion_shown":3,"suggestion_taken":1,"text_in":"今天开会","text_out":"今天开会。","ts":1793730973192}
{"app_id":"com.apple.TextEdit","device_id":"mac-you","keystroke_cadence":3.1,"kind":"key_session","text_in":"shijie","text_out":"世界","ts":1793730973184}
{"app_id":"com.apple.TextEdit","device_id":"mac-you","keystroke_cadence":3.2,"kind":"key_session","suggestion_shown":2,"suggestion_taken":1,"text_in":"ni hao","text_out":"你好","ts":1793730973174}
$ contextctl log export --format csv
ts,device_id,app_id,kind,text_in,text_out,ocr_digest,asr_digest,keystroke_cadence,suggestion_shown,suggestion_taken
1793730973231,mac-you,com.apple.loginwindow,key_session,留存默认关,,,,,,
1793730973209,mac-you,com.apple.loginwindow,suggestion_feedback,今天开会,今天开会——好的，我稍后处理,,,,3,1
1793730973201,mac-you,com.apple.TextEdit,candidate_pick,zni,智能,,,2.8,,
1793730973192,mac-you,com.apple.TextEdit,voice_session,今天开会,今天开会。,,,,3,1
1793730973184,mac-you,com.apple.TextEdit,key_session,shijie,世界,,,3.1,,
1793730973174,mac-you,com.apple.TextEdit,key_session,ni hao,你好,,,3.2,2,1

=== 5. suggest 客户端：Hub /v1/suggest SSE 流式刷新（localhost:8088） ===
hub-token: len=83（register 忽略 409 → token）
$ contextctl suggest --backend hub --text "今天开会"
suggest backend: hub http://localhost:8088  timeout=800ms（超时弃本轮，NFR3）
ctx: before_cursor=今天开会 from_voice=false
Δ + 164ms [1] 今天开会——好的，我稍后处理  (0.86 hub-stub)
Δ + 316ms [2] 今天开会——请稍等，马上回复  (0.74 hub-stub)
Δ + 470ms [3] 今天开会——谢谢，收到  (0.61 hub-stub)
✓ done +470ms（建议刷新完成）
$ contextctl suggest --backend null --text "语音转写"   # Null 后端离线兜底
suggest backend: null（离线兜底）  timeout=800ms（超时弃本轮，NFR3）
ctx: before_cursor=语音转写 from_voice=false
Δ +  90ms [1] 语音转写——本地兜底建议一  (0.62 null)
Δ + 205ms [2] 语音转写——本地兜底建议二  (0.51 null)
Δ + 289ms [3] 语音转写——本地兜底建议三  (0.44 null)
✓ done +289ms（建议刷新完成）
$ contextctl suggest --backend hub --text "超时用例" --timeout-ms 80   # 超时弃本轮（NFR3）
suggest backend: hub http://localhost:8088  timeout=80ms（超时弃本轮，NFR3）
ctx: before_cursor=超时用例 from_voice=false
⏱ timeout +114ms：timeout 80ms（弃本轮，NFR3）

=== 6. 动态提词器 · 终端流式面板（转写/上下文增量→建议实时刷新→Tab 采纳） ===
$ printf "今天开会\\n\\t\\n" | contextctl prompter --backend hub --from-voice
══ 动态提词器 · 终端流式面板演示 ══
感应点：⌥Esc（IME 热键唤起流式面板；语音中随转写 300–500ms 增量刷新）
backend: hub http://localhost:8088  timeout=800ms
命令：<文本>=转写/上下文增量  \t|tab=Tab 采纳  /1-9=选中  /q=退出

── 刷新 #1 · 增量「今天开会」（上下文累计 4 字）──
  Δ + 165ms [1] 今天开会——好的，我稍后处理  (0.86 hub-stub)
  Δ + 320ms [2] 今天开会——请稍等，马上回复  (0.74 hub-stub)
  Δ + 474ms [3] 今天开会——谢谢，收到  (0.61 hub-stub)
  ✓ done +474ms（建议刷新完成）
  · 增量事件入库 event_id=7（kind=voice_session）
[TAB] 采纳 → 今天开会——好的，我稍后处理  (score=0.86 source=hub-stub)
        · 采纳事件已入库 event_id=8（kind=suggestion_feedback）
提词器演示结束：共 1 轮刷新。
$ printf "语音转写\\n\\t\\n" | contextctl prompter --backend null   # 离线兜底
══ 动态提词器 · 终端流式面板演示 ══
感应点：⌥Esc（IME 热键唤起流式面板；语音中随转写 300–500ms 增量刷新）
backend: null（离线兜底）  timeout=800ms
命令：<文本>=转写/上下文增量  \t|tab=Tab 采纳  /1-9=选中  /q=退出

── 刷新 #1 · 增量「语音转写」（上下文累计 4 字）──
  Δ +  66ms [1] 语音转写——本地兜底建议一  (0.62 null)
  Δ + 127ms [2] 语音转写——本地兜底建议二  (0.51 null)
  Δ + 199ms [3] 语音转写——本地兜底建议三  (0.44 null)
  ✓ done +199ms（建议刷新完成）
  · 增量事件入库 event_id=9（kind=key_session）
[TAB] 采纳 → 语音转写——本地兜底建议一  (score=0.62 source=null)
        · 采纳事件已入库 event_id=10（kind=suggestion_feedback）
提词器演示结束：共 1 轮刷新。

=== 7. 剪贴板采集默认关（隐私红线：显式开关才采，且只记摘要/长度不记内容） ===
$ contextctl collect clipboard   # 未显式开启
clipboard_collection: off（默认关，需 --enable-explicit 显式开启）
$ contextctl collect clipboard --enable-explicit   # 显式开启（仅 demo）
clipboard_collection: explicit-enabled=true（仅记摘要与长度，不记内容）
clipboard sample stored: event_id=11（digest/len only）

=== 8. 熔断开关：开启后一切采集立即停（日志保留不新增） ===
$ sqlite3 "SELECT COUNT(*) FROM events"   # 熔断前
11
$ contextctl breaker status
breaker: off
$ contextctl breaker trip
breaker: TRIPPED（一切采集立即停；日志保留不新增）
$ contextctl collect inject ... （熔断后注入 → 期望拒收）
refused: circuit breaker tripped: collection stopped
  (exit=3 按预期拒绝)
$ printf "熔断后提词\\n\\t\\n" | contextctl prompter --backend null   # 采纳入库同样被拒
══ 动态提词器 · 终端流式面板演示 ══
感应点：⌥Esc（IME 热键唤起流式面板；语音中随转写 300–500ms 增量刷新）
backend: null（离线兜底）  timeout=800ms
命令：<文本>=转写/上下文增量  \t|tab=Tab 采纳  /1-9=选中  /q=退出

── 刷新 #1 · 增量「熔断后提词」（上下文累计 5 字）──
  Δ +  65ms [1] 熔断后提词——本地兜底建议一  (0.62 null)
  Δ + 247ms [2] 熔断后提词——本地兜底建议二  (0.51 null)
  Δ + 363ms [3] 熔断后提词——本地兜底建议三  (0.44 null)
  ✓ done +363ms（建议刷新完成）
  · 增量事件入库被拒：circuit breaker tripped: collection stopped
[TAB] 采纳 → 熔断后提词——本地兜底建议一  (score=0.62 source=null)
        · 入库被拒：circuit breaker tripped: collection stopped
提词器演示结束：共 1 轮刷新。
$ sqlite3 "SELECT COUNT(*) FROM events"   # 熔断后：应与熔断前一致
11
$ contextctl breaker reset   # 显式恢复
breaker: off（采集恢复）
stored: event_id=12 kind=key_session

=== 9. 30 天滚动 + 一键清空（可清） ===
$ contextctl log prune --days 30
pruned: 0 events older than 30d removed（30 天滚动）
$ contextctl log clear   # 一键清空
cleared: 12 events removed（一键清空完成；meta 保留）
$ sqlite3 "SELECT COUNT(*) FROM events"
0

=== DEMO: ALL STEPS EXECUTED ===
```

**验收序列对照**：① 注入会话事件（event_id 1–5 入库；安全输入/黑名单负例按预期拒收）→ ② 日志入库（第 6 条证明留存默认关 text_out 为空）→ ③ sqlite3 查询输出（.schema + 全字段行 + COUNT=6）→ ④ suggest 流式刷新（Hub SSE 3×Δ+done 470ms；Null 离线 3×Δ+done；--timeout-ms 80 超时弃本轮 kTimeout）→ ⑤ 熔断后停止入库（trip 后注入拒收、提词器采纳入库拒收，COUNT 11→11 不变；reset 后恢复 event_id=12）。提词器演示（第 6 节）：增量输入→Δ 帧实时刷新→[TAB] 采纳入库（suggestion_feedback taken=1），Hub 与 Null 后端各跑一遍。

## 4. 遗留与 blocker

1. **⌥Esc 热键注册本身不在本车道**：按目录所有权（§3.1）不写 `macos/`；本车道交付感应点文档（README「⌥Esc 感应点」表 + 接线约定）+ 终端形态演示（`prompter`）。真正的 ⌥Esc 热键/浮层 UI 由 W7 在 Squirrel/IMK 侧落地（M6 浮层属 IME 侧 UI）。
2. **frontmost 应用实测返回 `loginwindow`**：本执行环境的 GUI 会话前台是 loginwindow（远程/锁屏会话），NSWorkspace API 调用本身正常；真实用户会话中返回真实前台应用名。非代码缺陷，真机（W7 联调）复验。
3. **C1 不采集（MVP 仅 C0）**：`ocr_digest/asr_digest` 列与 C1 开关位已预留、默认 NULL；C1（屏幕 OCR/系统音频，仅输入时触发）待 M5 后续。
4. **剪贴板摘要是 FNV-1a 64 位**（非密码学哈希），仅用于「内容是否变化」对比；正式版换 SHA-256。剪贴板内容在任何路径都不落库（只记 digest+长度）。
5. **Hub `/v1/suggest` 仍是 W4 流式桩**（`hub-stub`）；llama.cpp 7B Q4 真后端接入后本客户端零改动（契约即协议，`backend` 字段已预留）。
6. **30 天滚动 prune 为手动触发**（`log prune`），MVP 未挂定时器/启动时自动清理；挂定时器留给集成阶段。
7. **提词器 Tab 采纳在管道输入下以 `\t` 行等价真实 Tab 键**（终端行缓冲语义）；IME 浮层中的真 Tab/数字/点按属 W7/M6 UI 层。
8. 交互日志尚未接 `/v1/ingest` 上行（W8 hub-client 负责同步 SDK）；本车道入库 API 已按 hub `IngestIn` 同构字段落库，导出 JSONL 可直接作为上行事件体。

## 5. 产物清单

- `context/Package.swift`、`context/.gitignore`
- `context/Sources/ContextCore/InteractionEvent.swift`（事件模型 + kind 枚举）
- `context/Sources/ContextCore/InteractionStore.swift`（SQLite store：查/导/清/滚动）
- `context/Sources/ContextCore/CircuitBreaker.swift`（熔断全局开关）
- `context/Sources/ContextCore/C0Collector.swift`（NSWorkspace + 入库 API + 剪贴板默认关）
- `context/Sources/ContextCore/SuggestClient.swift`（Hub SSE + Null + HubAuth + 800ms 超时语义）
- `context/Sources/contextctl/ContextCtl.swift`（CLI + 提词器流式面板）
- `context/Tests/ContextCoreTests/ContextCoreTests.swift`（11 用例全绿）
- `context/scripts/demo.sh`（可执行，验收序列）
- `context/README.md`、`context/W9-REPORT.md`
