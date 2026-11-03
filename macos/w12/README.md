# macos/w12/ —— W12 macos-C1：上下文引擎 C1 采集 MVP + 三线接线

> Wave 3 任务书：C1 采集（屏幕 OCR / 音频 ASR，**仅输入时**）+ W7×W9 接线 + ⌥Esc 提词浮层 + 隐私设置。
> 依据：docs/开发任务计划.md §3 约定、macos/W7-REPORT.md、context/W9-REPORT.md + context/README.md、
> voice/W2-REPORT.md、docs/技术方案-v0.4.md §8、docs/需求文档-v1.0.md FR4/FR5。
> **同一份源码双宿主**：`src/*.swift` 既编进 Squirrel.dev（pbxproj 直接引用），也编成 SwiftPM 包供脚本化实测。

## 组件

| 文件 | 职责 |
|---|---|
| `src/W12C1Collector.swift` | C1 采集编排：**仅输入时触发**（PTT 期间 + 按键触发窗）+ **防抖 2s**；屏幕快照→OCR→`ocr_digest`、音频→W2 管线→`asr_digest` 入库（仅摘要/长度） |
| `src/W12ScreenCapture.swift` | ScreenCaptureKit 屏幕快照（TCC 未授权→明确报错）+ 文件帧源（同一 OCR 链路） |
| `src/W12OCR.swift` | Vision OCR（zh-Hans/en-US，accurate）→ 摘要 |
| `src/W12AsrClient.swift` | voice/mic/ptt_daemon.py JSON-line 客户端（W2 管线；与 W7 同协议）+ WAV→16k mono |
| `src/W12Digest.swift` | **摘要/长度**（`sha256:<16hex> len:<n> lines:<m>`）——原文/原图/转写全文绝不落库 |
| `src/W12EventBridge.swift` | **W7×W9 接线唯一入口**：key_session / voice_session / candidate_pick / suggestion_feedback → W9 InteractionStore（C0Collector.record* 入库 API） |
| `src/W12PrompterModel.swift` | 提词浮层流式模型：SuggestClient（**Hub SSE / Null 双模**）→ Δ 帧实时刷新 → Tab 采纳（suggestion_feedback 入库） |
| `src/W12PrompterOverlay.swift` | **NSPanel 浮层**（非激活、不抢焦点；只建议不上屏，采纳才 commit） |
| `src/W12SquirrelGlue.swift` | Squirrel/IMK 接线（仅编进 app）：⌥Esc 热键、Tab/数字/Esc 采纳关闭、C1 输入触发、W7 事件上报挂点 |
| `src/W12Config.swift` | 隐私设置（C1 显式开关）+ **状态条指示色约定** |
| `tools/w12ctl/` | 脚本化实测 CLI（与 Squirrel 同一套 API） |
| `tests/W12CoreTests/` | 8 用例：摘要不落原文 / 防抖触发窗 / 隐私门禁 / OCR 入库 / W7×W9 上报 / 流式→采纳 |
| `scripts/w12-demo.sh` | 验收序列（全文输出见 macos/W12-REPORT.md §5） |
| `scripts/apply-w12.sh` + `squirrel-w12.patch` | Squirrel 树集成补丁（可复现记录） |

## 快速使用

```bash
swift build -c release && swift test          # 构建 + 8 用例
BIN=.build/release/w12ctl
DB=~/Library/Application\ Support/mine-input/interaction.db   # W9 同一库（--db 可覆盖）

$BIN privacy status | privacy c1 on|off       # C1 显式开关（默认关）+ 指示色约定
$BIN c1 trigger --keys 4 --image shot.png     # 防抖 2s 触发判定 + OCR 摘要入库
$BIN c1 ocr --image shot.png                  # 帧→Vision OCR→ocr_digest（sqlite3 可查）
$BIN c1 capture --source screen               # 真 ScreenCaptureKit（需屏幕录制 TCC）
$BIN c1 asr --wav ../../voice/audio/s1.wav    # 音频→W2 管线→asr_digest
$BIN bridge demo                              # W7×W9 三事件上报（Squirrel 同 API）
$BIN prompter --backend null --text "语音转写"  # 流式刷新 + Tab 采纳（Hub/Null 双模）
$BIN breaker trip|reset|status                # 熔断（W9 CircuitBreaker，跨进程）
bash scripts/w12-demo.sh 2>&1 | tee .demo/demo-output.txt    # 验收全链路
```

## 隐私红线（FR4/FR8，硬约束）

1. **C1 默认关、开关显式**：`W12C1Enabled`（Info.plist）默认 false；运行时只接受
   `W12Privacy.enableC1(explicitConfirm: true)` 显式开启（持久 store meta，跨进程）；
2. **仅输入时触发**：PTT 期间 + 按键触发窗，**防抖 2s**（NFR5）；
3. **仅摘要/长度入库**：`ocr_digest`/`asr_digest` = `sha256:… len:… lines:…`；
   原图、OCR 全文、ASR 全文任何路径都不落库、不落盘（单测断言）；
4. **密码框自动停不可关**：`IsSecureEventInputEnabled()`（Carbon HIToolbox）命中即拒收；
5. **敏感应用黑名单**命中跳过（C0Collector.defaultBlacklist）；
6. **熔断立即停**：W9 `CircuitBreaker`（全局持久）trip 后触发前/入库前双查 + store.insert 兜底拒；
7. 上屏文本留存（L3）默认关（text_out 恒空）。

## 状态条指示色约定（任务书 (d)，文档化）

| 状态 | 色值 | 含义 |
|---|---|---|
| 灰 | `#8E8E8E` | 采集关（C1 关：仅 C0 或全关） |
| 青绿 | `#388A83` | 采集正常（C0：输入历史/应用名） |
| 金 | `#D4A857` | C1 采集激活（快照/转写进行中） |
| 红 | `#C0453E` | 熔断开启 / 安全输入（密码框）暂停 |

实现常量：`W12StatusColor`（`src/W12Config.swift`）；菜单栏状态点/浮层状态行统一取色。
