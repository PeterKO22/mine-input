# 平价表 · macOS ↔ Android（W24 起维护）

> 规则：Mac（Tier A）为设计基准，Android（Tier B）逐项对齐；深水区只列 TODO 卡不展开。
> 证据列引用 e2e/实测口径；随每轮同步任务更新。
> 最后更新：W24（2026-11-04）

| # | 功能 | macOS 现状（基准） | Android 现状 | 差距 / 动作 | 状态 |
|---|------|---------------------|--------------|-------------|------|
| 1 | 英文输入 / 中英切换 | Shift 一键切换（`schema/default.yaml` ascii_composer `Shift_L/R: commit_code`：无编码=纯切换，有编码=原样上屏编码再切西文，再按切回；搜狗式，D 台账） | W24：工具栏「中/EN」键（持久状态，commit() 落盘）；EN 态字母/数字/符号直接上屏 ASCII（commit_code 语义），不过引擎、不等部署；混合场景=中文串一键插英文；中文态数字键 1-9 选候选 | 形态差异（Mac=Shift 键 / Android=工具栏键，按平台习惯），语义对齐 | ✅ 平 |
| 2 | 横向候选 | `candidate_list_layout: linear`（squirrel-linear.patch 幂等套入） | W5 起候选栏即横排（M1 单行 ≤6，序号 gold mono / 当前候选金填充） | 基本平；>6 候选无翻页 → TODO-E | ✅ 平（小尾巴） |
| 3 | AI 智能候选组 | 「AI 智能列」cyan 描边玻璃卡与五笔/拼音组区分（design-language M1）；来源 SuggestClient（Hub SPI suggest） | W24：标记管道 + 渲染落地（候选 ai 标志 → cyan 玻璃卡 + 「AI」角标，w24_aimark 演示位）；真实 AI 来源未接 | 标记已平；候选来源接入 → TODO-C | 🟡 部分 |
| 4 | PTT 语音 | 全管线（sherpa-onnx：VAD→SenseVoice→标点→热词；按住即说；语音中随转写提词） | W14 全管线（PTT 大键：按住即说 / 滑出取消 / 返回取消 / 低置信重说 / 滚动转写；16k mono 内存缓冲） | 基本平；语音中 AI 提词依赖 TODO-C | ✅ 平 |
| 5 | 提案卡 | W20：SPI v2（propose 流式 / confirm 显式确认 / observe 回填）+ Null 桩红线「未 confirm 不得执行」+ 卡片 UI（queued→running→done） | 无 | 深水区 → TODO-A（本期不展开） | ❌ TODO-A |
| 6 | 记忆管理 | W20：⌥M 浮层（按日时间线 / 编辑 situation·my_reply / 删除 / 搜索 / 导出 + 采集状态 + 熔断 CircuitBreaker 同源） | 设置页部分等价（撤回同意 / 一键熔断 / 数据导出，W11）；无记忆时间线管理 UI | 深水区 → TODO-B（本期不展开） | ❌ TODO-B |
| 7 | 产品名 | W18：「提炼输入法」/ "Mine Input"（TIS 输入源 + 菜单栏本地化） | W18：app_name/ime_name 同名（values / values-en），aapt badging ALL PASS | 无 | ✅ 平 |
| 8 | 密码框隐私（C1，W24 新增口径） | 需求文档 v1.0：「密码框/支付场景（Secure Input）自动暂停、不可关闭」；ContextCore `secureInput` → `refused(.secureInputPaused)` | W24：textPassword / textVisiblePassword / webPassword / numberPassword 检测 → 自动 EN + 采集闸关死（SyncManager.collectionPaused，candidate_pick/voice_session 一律拒收）+ 不调 AI/云端 + 离开恢复原模式（密码框强制 EN 不可切） | 支付场景 / 敏感应用黑名单 → TODO-D | ✅ 平（扩展了自动 EN） |

## TODO 卡（深水区，另行立项）

- **TODO-A 提案卡 Android 版**：SPI v2 propose/confirm/observe 契约移植 + 显式确认红线（未 confirm 不得执行）+ 卡片 UI 状态机（queued→running→done）。
- **TODO-B 记忆管理 Android 版**：记忆时间线 / 编辑 / 删除 / 搜索 / 导出 + 采集状态常显 + 熔断联动（与 ⌥M 浮层同构）。
- **TODO-C AI 智能候选真实来源**：接 Hub SPI suggest（SuggestClient 同契约）/ 端侧 GGUF 兜底；候选进 ai 标记管道（W24 已备好渲染）。
- **TODO-D 敏感应用黑名单 + 支付场景**：Mac 同款「自动暂停不可关」扩展到应用维度。
- **TODO-E 候选翻页**：>6 候选滑动/Tab 轮换（对齐 Mac rotate_candidate_with_tab）。
