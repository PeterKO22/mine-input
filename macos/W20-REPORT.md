# W20 proposal-ui 交付报告

> 车道：W20 proposal-ui（Wave 6）｜日期：2026-11-04｜环境：macOS 27.0.1 arm64 / Xcode 27.2 / Swift 6.4.2
> 范围：`ai/` `macos/`（含 `macos/w20/` 新实现件 + `macos/squirrel/` 工作树集成 3 文件）｜依据：docs/技术方案-v0.4.md §15.2（提案→确认→执行契约）/§15.3（记忆管理界面）/§15.1（记忆 JSONL schema）、docs/需求文档-v1.0.md N7/N8、ai/W3-REPORT.md + ai/spi/ai_assist.h（v1 契约不动）、macos/W7/W12/W18-REPORT.md（Squirrel-dev 构建安装与浮层现状）、design/design-language.md

---

## 0. 一句话结论

**四项交付全部落地并实测：(a) `ai/spi/ai_assist_v2.h` 提案契约 v2（propose 流式提案 / confirm 显式确认→ExecutionHandle / observe 进度回填，v1 五方法不动、注释注明远程同契约）；(b) Null 提案桩（C++ `NullProposalAgent` + Swift 镜像）+ 单测含红线断言「未 confirm 不得执行」全绿（ctest 4/4，SwiftPM 15/15）；(c) macOS 记忆管理浮层（⌥M/菜单项入口、顶部常显采集状态+一键熔断、时间线按日分组、单条查看/编辑 situation·my_reply、删除、搜索、导出，深色科幻对齐 design-language）；(d) 提案卡 UI（方案卡标题/详情/动作清单 + 显式「确认执行」按钮，接 Null 桩演示 queued→running→done state 流转；Squirrel 内接的是 C++ 桩本尊，经 ObjC++ 桥）；`build-squirrel.sh` 重跑 BUILD SUCCEEDED + `install-dev.sh` 重装 EXIT=0（IME 进程存活门过，符号实证 W20 桥/C++ 桩在已装二进制内）；脚本化验收 `w20-demo.sh` 29 项断言 ALL GREEN。界面实机交互按任务书留手动步骤（§6，本环境禁 computer_use）。**

---

## 1. 交付物清单

| 路径 | 说明 |
|---|---|
| `ai/spi/ai_assist_v2.h` | (a) 提案契约 v2：`Proposal{id,kind(reply|task|plan),title,detail,actions}` / `ExecutionHandle{id,proposal_id,state(queued|running|done|failed),progress,result}` / `ProposalStream`（流式）/ `AiAssistV2 : AiAssist`（v1 五方法继承不动）+ propose/confirm/observe；注释注明**远程同契约**（§7 原则，Hub 执行器位同签名）+ 红线四条 |
| `ai/backends/null/null_proposal_agent.{h,cc}` | (b) Null 提案桩：propose 流式 1 条示例提案+恰好一次终止（secure_input 未受理）、confirm 执行唯一入口（未知 id→kFailed、重复幂等）、observe 演示 queued→running(0.5)→done(1.0)，v1 五方法委托 NullAiAssist（不动） |
| `ai/tests/test_proposal_v2.cpp` + `ai/CMakeLists.txt` | (b) 单测 8 组断言：红线 ①propose 后 `execution_count()==0` ②伪造 handle observe 拒绝且不执行 ③confirm 是唯一执行入口 ④重复 confirm 幂等不二次执行；另覆盖流式终止语义/secure_input/v1 委托。**在 ai/ 内注册（`enable_testing()+add_test`），不动 `tests/` 车道文件** |
| `macos/w20/src/W20MemoryStore.swift` | (c) 数据层：§15.1 schema 宽容解析、按日分组、搜索（keyword→my_reply.text/before_cursor/thread，app/since 过滤）、编辑（重写当日文件；未提及字段保留、未改动行字节级原样）、删除（物理移除该行，空文件移除）、导出 JSONL、采集状态（熔断态+今日/累计） |
| `macos/w20/src/W20MemoryPanel.swift` | (c) 界面：顶部常显（状态点+「采集中/已熔断」+今日·累计条数+一键熔断开关）→ 分段（记忆时间线/提案卡）→ 左时间线（日分组）右详情（situation.before_cursor/thread、my_reply.text 编辑 + 保存/删除/导出此条/导出…）；`debugDump()` 供脚本化形态断言 |
| `macos/w20/src/W20ProposalCard.swift` | (d) 提案卡：标题（gold）/kind chip（cyan）/详情/动作清单（○ 金勾行）+ **显式「确认执行」主按钮（全工程 engine.confirm 唯一调用点）**；state chip（queued 金/running 青/done 绿/failed 红）+ 金渐变进度条 + 结果行；确认后按钮禁用（不二次执行），「重新提案」只重跑 propose |
| `macos/w20/src/W20ProposalModel.swift` | (d) 契约 Swift 镜像 + `W20ProposalEngine` 协议 + `W20NullProposalEngine`（逐条对齐 C++ 桩：同提案内容/同红线/同状态流转） |
| `macos/w20/src/W20SquirrelGlue.swift` + `bridge/W20ProposalBridge.{h,mm}` | (d) Squirrel 接线：⌥M 热键拦截；`W20CppProposalEngine` 经 ObjC++ 桥驱动 **C++ `NullProposalAgent`**（与 ai/ 单测同一个桩）；熔断用 W12EventBridge 的 CircuitBreaker（store meta，跨进程同源） |
| `macos/w20/src/W20Design.swift` | design-language token（bg `#0E2924`/card `#18352F`/stroke `#2B4B44`/gold `#D4A857`/cyan `#388A83`/red `#A84B3D`/green `#4CB368`；文字 #E0E6E4/#C8D0CC/#8A9E99；数值 mono+微发光；主/次/危险按钮形态） |
| `macos/w20/tools/w20ctl/main.swift` | 脚本化实测 CLI：list/show/search/edit/delete/export、breaker status\|trip\|reset、proposal demo、panel-dump |
| `macos/w20/tests/W20CoreTests/` | 15 用例全绿（数据层 7 + 提案红线镜像 8） |
| `macos/w20/scripts/w20-demo.sh` | 验收序列（6 段 29 项断言，ALL GREEN，输出 §5） |
| `macos/w20/squirrel-w20.patch` + `scripts/apply-w20.sh` | Squirrel 集成增量补丁（只动 pbxproj/桥接头/SquirrelInputController 3 文件；`git apply --reverse --check` 过，§7） |
| `macos/w20/README.md` | 组件/用法/红线 |
| `macos/W20-REPORT.md` | 本报告 |

**目录纪律**：只写 `ai/` 与 `macos/`；`tests/`、`build/`、`context/`、`docs/` 未动（ai 单测在 `ai/tests/` 内注册）。Squirrel 工作树改动收敛进 `macos/w20/squirrel-w20.patch`。

---

## 2. (a) SPI v2 契约（`ai/spi/ai_assist_v2.h`，契约先行）

```cpp
struct Proposal { std::string id; ProposalKind kind;      // reply | task | plan
                  std::string title, detail;              // 方案本体
                  std::vector<Action> actions; };         // 可执行动作清单
struct ExecutionHandle { std::string id, proposal_id;
                         ExecutionState state;            // queued|running|done|failed
                         double progress; std::string result; };

class AiAssistV2 : public AiAssist {   // v1 五方法保留不动（继承）
  Status propose(const AiContext&, ProposalStream&);      // 流式提案
  ExecutionHandle confirm(const std::string& proposal_id); // 显式确认 → 执行
  Status observe(const ExecutionHandle&, const ProgressCb&); // 进度/结果回填
};
```

- **v1 五方法不动**：`ai/spi/ai_assist.h` 一字未改（git diff 可证）；v2 以继承方式增量，Null 桩的 v1 方法逐个委托 `NullAiAssist`；
- **远程同契约**（§7 原则）：头部注释明确「本地调用与 Hub 远程协议同方法签名，换后端/换通道零改动，W4 起 HTTP 映射」；Hub 侧执行器位（agent runner）随 Hub 迭代落地（§15.2 v2 实施顺序：本版只做契约+Null 桩+提案卡形态）；
- **红线写进契约注释**：①confirm 必须用户显式动作，自动执行不存在 ②执行从 confirm 起算 ③伪造/未知执行 id 的 observe 必须拒绝 ④重复 confirm 幂等（同 handle.id，不二次执行）；
- 流式提案语义对齐 v1 suggest 语义族：非 kOk 未受理不触碰 stream；受理后若干 `on_proposal` + 恰好一次终止（`on_done`/`on_error`）；终止后更新必须丢弃。

## 3. (b) Null 提案桩 + 单测（红线断言）

`NullProposalAgent`（C++，`ai/backends/null/`）行为：propose 恒定输出 1 条 `prop-null-1`（kPlan「Null 示例方案」，3 动作）后 on_done；confirm 只入队（kQueued）；observe 回填 running(0.5)→done(1.0, result=「null 执行完成：…」)；未知 id→kFailed handle 不执行；`execution_count()` 内省供红线断言。

单测 `ai/tests/test_proposal_v2.cpp`（在 `ai/CMakeLists.txt` 注册，不动 `tests/` 车道文件；断言头复用 `tests/test_assert.h`）关键断言：

```
红线①：propose 之后 CHECK(agent.execution_count() == 0)          // 未 confirm 不得执行
红线②：observe(伪造 handle) == kError，回调 0 次，count 仍 0      // 不执行
红线③：confirm 后 count == 1 且 handle.state == kQueued           // 执行唯一入口
红线④：重复 confirm 同 handle.id，count 仍 1                      // 不二次执行
```

**ctest 输出（`ctest --test-dir build`，含 v1 三测不动全绿）：**

```
1/4 Test #1: test_proposal_v2 ....... Passed   ← W20 新增
2/4 Test #2: test_null_backend ...... Passed
3/4 Test #3: test_timeout ........... Passed
4/4 Test #4: test_stream ............ Passed
100% tests passed, 0 tests failed out of 4
```

Swift 侧镜像桩（`W20NullProposalEngine`）同题断言 8 用例 + 数据层 7 用例 = `swift test` **15/15 全绿**（`Executed 15 tests, with 0 failures`）。镜像契约由 `testCPlusPlusStubParity` 钉住（同提案 id/kind/title/动作 id 序列）。

## 4. (c) 记忆管理界面 + (d) 提案卡（UI 形态）

**入口**（§15.3 菜单栏/浮层入口）：IME 内 **⌥M**（`SquirrelInputController.handle()` 拦截，不进 rime）或输入法菜单 **「记忆管理…（⌥M）」**（menu() 新增项）→ `W20MemoryPanel` 浮层（floating NSPanel）。

**顶部常显**：状态点（采集中=cyan / 已熔断=red）+「采集状态：采集中 / 已熔断（停采集）」+ 今日 N 条·累计 M 条（gold mono）+ **一键熔断开关**（NSSwitch）——熔断写 ContextCore `CircuitBreaker`（store meta `breaker`，跨进程持久，与 W12 采集链路、W19「熔断停记」**同一开关**）。

**记忆时间线**（左）：按日分组（`2026-11-04 · N 条` gold mono 头 + 条目行：ts mono / my_reply / app chip）；**搜索框**即时过滤（命中 my_reply.text / situation.before_cursor / situation.thread）。**详情**（右）：meta chips（id/ts/app/consent/mode/conf）+ 可编辑 `situation.before_cursor`、`situation.thread`（每行一条）、`my_reply.text` + 按钮组「保存修改（金主按钮）/ 删除（危险，确认弹窗）/ 导出此条 / 导出…（NSSavePanel→JSONL）」。数据操作全部走 `W20MemoryStore`（§15.1 语义：编辑重写当日文件、删除即物理移除该行）。

**提案卡**（分段第 2 页）：方案卡 = 标题（gold 14 Bold）+ kind chip（cyan）+ 详情 + 动作清单（○ 金勾行）+ **「确认执行」主按钮**（实心暖金+微光晕，design-language §4）；确认后 state chip 流转 `queued(金)→running(青)→done(绿)` + 金渐变进度条（0→0.5→1.0）+ 结果行（绿），按钮随即禁用；「重新提案」只重跑 propose（只提案不执行）。**红线落位：`engine.confirm` 全工程唯一调用点 = 该按钮的 action**（代码注释已标）。

**接 Null 桩**：Squirrel.app 内提案卡引擎 = `W20CppProposalEngine` → `W20ProposalBridge`（ObjC++）→ **C++ `NullProposalAgent`**（`null_proposal_agent.cc` 编入 app，已装二进制符号实证 `_OBJC_CLASS_$_W20BProposalAction/W20BProposalItem`、`N4mine2ai17NullProposalAgentE`）——与 §3 单测断言的是同一个桩。SwiftPM 独立侧（w20ctl/单测）用同契约 Swift 镜像桩。

视觉对齐 design-language：深色 bg/card/stroke、gold 主强调（确认按钮/数值/进度条）、cyan 次强调（running/流转）、red 危险（删除/熔断）、green 完成、文字三级层级、数值 mono 微发光、8/4 圆角、1px 描边。

## 5. 验收

### 5.1 构建重装（验收硬项）

```
bash build/build-squirrel.sh   → BUILD_EXIT=0   ** BUILD SUCCEEDED **
   artifact: macos/squirrel/build/Build/Products/Release/Squirrel.app
   CFBundleIdentifier=im.rime.inputmethod.Squirrel.dev  CFBundleName=Mine Input
bash build/install-dev.sh      → INSTALL_EXIT=0（[4/5] IME 进程存活门过）
   pgrep: 30290 …/Library/Input Methods/Squirrel-dev.app/Contents/MacOS/Squirrel
   已装二进制符号实证：W20 ObjC 桥类 + mine::ai::NullProposalAgent + 354 个 W20 nm 符号
```

### 5.2 单测

- C++ `ctest --test-dir build`：**4/4 全绿**（test_proposal_v2 新增 + v1 三测不动）；
- `swift test`（macos/w20）：**15/15 全绿**（W20MemoryStoreTests 7 + W20ProposalEngineTests 8）。

### 5.3 脚本化验收 `bash macos/w20/scripts/w20-demo.sh`（29 项断言，输出摘录）

```
== [1/6] ai/ C++ 单测（提案契约 v2 + 未 confirm 不得执行）==   [PASS] ctest 全绿（4 个）
== [2/6] macos/w20 SwiftPM 单测 ==                            [PASS] swift test 15/15 全绿
== [3/6] w20ctl 数据层（时间线/搜索/编辑/删除/导出）==
  [PASS] 按日分组（新日在前）  [PASS] 搜索 keyword 命中 my_reply  [PASS] 搜索 keyword 命中 thread
  [PASS] 编辑 situation+my_reply  [PASS] situation 已重写当日文件  [PASS] 未提及字段（mode）保留
  [PASS] 未改动行字节级原样  [PASS] 删除（物理移除该行）  [PASS] m-1 行已不存在（物理移除）  [PASS] 导出 JSONL
== [4/6] 一键熔断（ContextCore CircuitBreaker 同源）==
  [PASS] 熔断生效  [PASS] 状态=熔断中  [PASS] 解除熔断
== [5/6] 提案卡 state 流转（Null 桩）==
  [PASS] propose 后未执行（红线）  [PASS] 伪造 handle 被拒（红线）
  [PASS] confirm → queued  [PASS] observe → running  [PASS] observe → done（执行到出结果）
  [PASS] 重复 confirm 幂等
== [6/6] 界面形态 dump（记忆管理 + 提案卡）==
  [PASS] 顶部采集状态常显  [PASS] 一键熔断开关  [PASS] 时间线按日分组
  [PASS] situation 编辑区  [PASS] my_reply 编辑区  [PASS] 保存/删除/导出按钮
  [PASS] 提案卡标题/详情/动作清单  [PASS] 显式确认执行按钮

PASS=29 FAIL=0
W20-DEMO ALL GREEN
```

state 流转实测（`w20ctl proposal demo`）：`propose → executionCount=0（红线）→ observe(forged)=refused ✓ → confirm: exec-null-1 state=queued → observe: running(0.5) → done(1.0,「null 执行完成：Null 示例方案（3 个动作）」) → 重复 confirm 同 id 幂等，executionCount=1`。

数据层编辑语义实测（w20ctl edit 后逐行比对）：改动行重写（`before_cursor`/`thread`/`text` 更新、未提及的 `mode`/`screen_digest` 等字段保留），同文件未改动行**字节级原样**。

### 5.4 界面手动步骤（实机；本环境禁 computer_use，逐步人工验证）

1. 重装后切到「提炼输入法」，任意 App 中按 **⌥M**（或输入法菜单 →「记忆管理…（⌥M）」）→ 浮层弹出（未弹：`open ~/Library/Input\ Methods/Squirrel-dev.app` 后重试）。
2. 顶部常显核对：状态点+「采集状态：采集中」+今日/累计条数；拨「一键熔断」开关 → 变「已熔断（停采集）」红点；终端 `w20ctl breaker status` 应同步 TRIPPED（跨进程同源）；拨回恢复。
3. 左侧时间线按日分组；搜索框输关键词 → 列表即时过滤；清空恢复。
4. 点条目 → 右侧详情；改 `before_cursor`/`thread`（每行一条）/`my_reply.text` → 「保存修改」→ 重开浮层数据保留（或 `w20ctl show --id …` 复核）。
5. 「删除」→ 确认弹窗「删除即物理移除该行」→ 确认后条目消失、文件中该行不存在。
6. 「导出…」/「导出此条」→ NSSavePanel 存 `.jsonl`，内容与 schema 一致。
7. 切「提案卡」页：核对方案卡（标题「Null 示例方案」/详情/3 项动作清单）→ 点 **「确认执行」** → state chip 依次 queued(金)→running(青)→done(绿)，进度条 0→50%→100%（金渐变），结果行「null 执行完成：…」；按钮变灰不可再按；「重新提案」刷新提案（不执行）。
8. 常态回归：⌥Esc 提词浮层（W12）、右⌘ PTT（W7）不受影响（W20 只拦截 ⌥M）。

## 6. Squirrel 集成补丁（可复现）

`squirrel-w20.patch` = 相对 dev+w7+linear+w12 状态的**增量**（只动 3 文件：`project.pbxproj` 编入 6 个 w20 Swift + W20ProposalBridge.mm + null_proposal_agent.cc、`Squirrel-Bridging-Header.h` 暴露桥、`SquirrelInputController.swift` ⌥M 拦截+菜单项）。实测：当前树 `git apply --reverse --check` **PASS**；pristine 复现顺序 dev→w7→linear→w12(`apply-w12.sh`)→w20(`apply-w20.sh`)。

## 7. 诚实记录 / 限制

1. **界面实机手测未做**：本环境禁 computer_use。界面形态已脚本化实证（`panel-dump` 断言顶部状态/熔断开关/时间线分组/编辑区/按钮/提案卡全要素，且从同一份源码编译），但浮层在真机上的交互手感、⌥M 在具体 App 内的响应、NSSavePanel 流程需按 §5.4 人工过一遍。
2. **W19 并行未落地**：记忆写入侧（事件→情境/回复配对）由 W19 交付；本车道按 §15.1 定死的 schema 开发读写，验收用 fixture/w20ctl 造数。与 W19 的端到端联调（真记忆文件进界面）待其落地后一轮即可，无契约风险（schema 已冻结）。
3. **执行器不在本版**：§15.2 明确 v2 实施顺序——本版契约+Null 桩+提案卡形态；真实任务执行（Hub agent runner）随后续 Hub 迭代，提案卡 result 为 Null 桩演示文本。
4. **⌥M 与 ⌃⌥M**：W7 PTT 兜底开关占 ⌃⌥M（control+option+M），W20 用 ⌥M（option+M），不冲突；⌥M 会吞掉该组合（不再上屏 µ 等 Option 字符）——任务书指定入口，若实测影响输入习惯可退化为仅菜单项（一行开关）。
5. `tests/` 车道文件未动（约束「只写 ai/ 与 macos/」）：ai 单测注册在 `ai/CMakeLists.txt`（`enable_testing()+add_test`），ctest 从 build/ 根统一拾取（实测 4/4）。
6. 优化构建（-O）下 Swift 字面量在二进制中的存储形态导致部分 UI 中文串 `strings/grep` 不可见（非缺失）——UI 文本完整性由 `panel-dump` 从同源码实证。
