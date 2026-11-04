# macos/w20 — proposal-ui：提案契约 v2 UI + 记忆管理界面（N7/N8）

> 依据：docs/技术方案-v0.4.md §15.1–§15.3、docs/需求文档-v1.0.md N7/N8、
> design/design-language.md（深色科幻）、ai/spi/ai_assist_v2.h（提案契约唯一事实源）。
> 记忆 JSONL schema 由 W19 交付（§15.1 定死）——本目录按 schema 读文件开发，不等 W19。

## 组件

| 路径 | 说明 |
|---|---|
| `src/W20MemoryStore.swift` | 记忆数据层：按日分组加载 / 搜索（keyword/app/since）/ 编辑（重写当日文件，未改动行字节级原样）/ 删除（物理移除该行）/ 导出 JSONL + 采集状态（熔断同源） |
| `src/W20ProposalModel.swift` | 提案契约 Swift 镜像（Proposal/ExecutionHandle/propose→confirm→observe）+ Null 提案桩 Swift 镜像（对齐 `ai/backends/null/null_proposal_agent.cc`） |
| `src/W20ProposalCard.swift` | 提案卡：方案卡（标题/详情/动作清单）+ 显式「确认执行」+ state 流转（queued→running→done，金渐变进度条） |
| `src/W20MemoryPanel.swift` | 记忆管理浮层：顶部常显采集状态 + 一键熔断；时间线按日分组 / 查看编辑 situation·my_reply / 删除 / 搜索 / 导出 |
| `src/W20Design.swift` | design-language 深色科幻 token（bg/card/stroke/gold/cyan/red/green、mono 数值） |
| `src/W20SquirrelGlue.swift` | Squirrel 接线（仅编进 app）：⌥M 热键 + `W20CppProposalEngine`（ObjC++ 桥驱动 **C++ Null 提案桩**） |
| `bridge/W20ProposalBridge.{h,mm}` | ObjC++ 桥（仅编进 app）：包装 `mine::ai::NullProposalAgent` |
| `tools/w20ctl/` | 脚本化实测 CLI：list/show/search/edit/delete/export、breaker、proposal demo、panel-dump |
| `tests/W20CoreTests/` | 15 用例（数据层 + 提案红线「未 confirm 不得执行」镜像断言） |
| `scripts/w20-demo.sh` | 验收序列（29 项断言，ALL GREEN） |
| `squirrel-w20.patch` + `scripts/apply-w20.sh` | Squirrel 树集成补丁（可复现记录；`git apply --reverse --check` 实测过） |

## 红线（§15.2，不可协商）

`confirm` 必须用户显式动作（提案卡「确认执行」按钮）——**自动执行不存在**：
propose 只提案不执行；未经 confirm 的执行 id observe 直接拒绝。
C++ 桩（`ai/`）与 Swift 镜像桩同语义；Squirrel 内提案卡接的是 C++ 桩（同单测断言对象）。

## 用法

```bash
swift build && swift test            # 本包构建 + 15 用例
.build/debug/w20ctl list --dir ~/Library/Application\ Support/mine-input/memory
.build/debug/w20ctl proposal demo    # 提案卡 state 流转（红线断言）
bash scripts/w20-demo.sh             # 验收序列（29 项）
```

浮层入口：IME 内 ⌥M 或输入法菜单「记忆管理…（⌥M）」。
