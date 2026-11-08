# W28 ptt-lock — 右⌘ 长按锁定录音（免手持长语音）

> 状态：**代码 + 单测交付完成，全绿**；装机验收待用户输入法会话恢复后按 §6 清单人工执行。
> 红线遵守：全程未 install、未 open/launch 任何 Squirrel.app（构建仅编译验证，见 §7）。

## 1. 需求与规格（歧义处按对称性定死）

用户原话：「按住右⌘ 10秒以上，就锁住（界面要有变化，提示可以松开按键了），等再次按一次，
且少于10秒才停止。防止长时间说话要一直按着」。

| # | 规格 | 实现落点 |
|---|---|---|
| ① | 按住 <10s 松开 → 停止上屏（现行为不变） | `W7PttLockMachine.pressEnded()` → `stopAndProcess` → 既有转写上屏链 |
| ② | 按住 ≥10s → 锁住：面板立刻变锁定态（文案含「可以松开按键了」），后续松手不停 | `tick()`/松手补判跨阈值 → `lock`（**只触发一次**）→ `w7ShowLockedHint()`；锁定后原长按的松手 → `none` |
| ③ | 锁定中再按右⌘：本次 <10s 松开 → 停止上屏；又按住 ≥10s → 维持锁定（可再触发锁定提示） | 停止手势（pressBegan 于 locked）：<10s 松开 → `stopAndProcess`；≥10s → `relock`（只触发一次）后仍需一次 <10s 轻点才停 |
| ④ | Esc 随时取消（录音 + 锁定） | `escape()` 任意非 idle 态 → `cancel(.escape)` 丢弃音频 |

对称性定死的歧义点（规格未明说处）：
- **松手时刻 ≥10s 但 tick 未赶上**（如定时器延迟）→ 算锁定（补触发 lock），松手不停（与②对称）。
- **组合键（⇧/⌃/⌥ 出现）**：录音中取消放行是 W7 现行为；锁定态对称同样取消。
- **⌃⌥M latch（兜底开关）**：本就免手持，**永不触发锁定**（不计按住时长）；录音/锁定中按 ⌃⌥M → 停止上屏。
- **锁定中误触其它 ⌘（左⌘ 单击）**：不停不取消（停止手势只认右⌘）。
- 锁定提示用 `showPanel(preedit:)`，**不收口 W12 触发窗**（无 `notePttEnd`——仍在 PTT 语音窗内采集）；
  聆听态文案原样保留（含 W27 读屏接线 `notePttStart` 不动）。

## 2. 状态机（W7PttLockMachine，纯 Foundation）

```
                 pressBegan（右⌘ 按下，单修饰键）
      ┌──────────────────────────────────────────────────┐
      │                                                  │
      ▼                                                  │
 ┌─────────┐  pressBegan / beginLatch(⌃⌥M)   recording（🎙 聆听态）
 │  idle   │ ─────────────────────────────► │  按住计时（伪时钟）
 └─────────┘                                │
      ▲   ▲   ▲                             ├─ 松开 <10s ──────────► stopAndProcess（①）
      │   │   │                             ├─ tick/松开 ≥10s ────► lock（②，触发一次）
      │   │   └── cancel：Esc（④）/组合键 ──┤
      │   │                                 ▼
      │   └──── cancel：Esc（④）──────  locked（🔒 已锁定·可以松开按键了）
      │                                     │
      │                                     ├─ 原长按松手 ──► locked（不停，②）
      │                                     ├─ pressBegan（③停止手势）
      │                                     │    ├─ <10s 松开 ──► stopAndProcess（③）
      │                                     │    └─ ≥10s ──────► relock 维持锁定（③，触发一次）
      │                                     │         └─ 松手 → locked；再轻点 <10s → stopAndProcess
      │                                     └─ ⌃⌥M ────────────► stopAndProcess
      └──────────────────────────────────────────────────────────┘
```

- 阈值常量（命名）：`W7PttLockMachine.lockThresholdSeconds: TimeInterval = 10.0`（≥ 阈值即锁定）。
- **时钟注入**（W27-fix 同款硬约束）：`clock: () -> TimeInterval = { Date() }`，单测伪时钟推进，
  **零 Thread.sleep**；生产行为不变。
- lock / relock 各**每次按住只触发一次**（`thresholdNotified` 防重复提示）。

## 3. UI（SquirrelInputController，Squirrel 面板 preedit 行）

| 状态 | 文案 | design-language.md 映射 |
|---|---|---|
| 聆听态（**不变**） | `🎙 正在聆听…（松开上屏 · Esc 取消）` | 听写中 = cyan（`#388A83`）语义 |
| 锁定态（新增 `w7ShowLockedHint()`） | `🔒 已锁定录音中…（可以松开按键了 · 轻点右⌘ 停止上屏 · Esc 取消）` | 锁定 = gold（`#D4A857`）主强调/选中态语义 |

含「可以松开按键了」字样与 🔒 +「已锁定」标识，与聆听态明显区分（emoji + 文案双重区分；
Squirrel 面板 preedit 为纯文本通道，色彩以语义 token 映射记录，如上）。

## 4. 伪时钟单测（新文件，零 sleep）

- `macos/w7/src/W7PttLockMachine.swift`（被测状态机，macos/w7 唯一事实源）
- `macos/w7/tests/test_ptt_lock.swift`（56 断言）+ `build/w7-test-ptt-lock.sh`（swiftc 独立编译运行，
  产物 `build/w7/tests/test_ptt_lock`，日志 `build/logs/w7-test-ptt-lock.log`；不触 TCC、不拉起 app）

必需用例全数覆盖（每条均注入伪时钟推进，全文零 `Thread.sleep`）：

| 用例 | 期望 | 结果 |
|---|---|---|
| 9s 松开 | 停止上屏（①现行为不变） | PASS |
| 10.1s 跨阈值 | 锁定（lock 触发一次）且松开不停（②） | PASS |
| 锁定中 0.2s 轻点 | 停止上屏（③） | PASS |
| 锁定中 5s 松开 | 停止上屏（③） | PASS |
| 锁定中 12s | 维持锁定（relock）后再轻点 → 停止（③） | PASS |
| Esc | 录音中/锁定中均取消，空闲不拦截（④） | PASS |

边界补充（防误停/误锁）：恰好 10.0s 锁定、9.999s 不锁、无 tick 直接 10.1s 松开 → 补锁不停、
lock/relock 各只触发一次、组合键取消（录音+锁定对称）、⌃⌥M 显式停止、latch 30s 永不锁定、
`secondsToThreshold()` 排程辅助（≈10s→≈6s→锁定后 nil）、阈值常量 == 10.0。

**结果：56/56 ALL PASS**（`build/logs/w7-test-ptt-lock.log`）。

## 5. 验收（本次执行）

| 项 | 命令 | 结果 |
|---|---|---|
| W28 新单测 | `bash build/w7-test-ptt-lock.sh` | **56/56 ALL PASS**，零 sleep |
| 既有单测无回归 · context | `cd context && swift test` | **37/37**（MemoryCore 18 + ContextCore 19） |
| 既有单测无回归 · w12 | `cd macos/w12 && swift test` | **16/16**（W12CoreTests 8 + W27InputEventTests 8） |
| 既有单测无回归 · w7 rescore | `bash build/w7-test-rescore.sh` | **ALL PASS**（22/22 断言） |
| 全 app 目标编译 | `xcodebuild -project Squirrel.xcodeproj -configuration Release -scheme Squirrel … build`（构建树，**未 launch**） | **BUILD SUCCEEDED**（W7PttLockMachine 编入、W7PttController 重构与 w7ShowLockedHint 均过编译） |

可复现记录：`macos/w28/squirrel-w28.patch`（SquirrelInputController.swift 新增 w7ShowLockedHint +
project.pbxproj 编入 ../w7/src/W7PttLockMachine.swift，FA70…A6/B6 id）+ `macos/w28/scripts/apply-w28.sh`
（幂等，已实测 `git apply --reverse --check` 通过 + 重跑输出 already applied）。

## 6. 手工验收清单（装机后真人执行——本任务按约束不 install、不 open，留待用户输入法会话恢复）

1. **真人长按右⌘ >10s** → 面板出现「🔒 已锁定录音中…（可以松开按键了 …）」（听到/看到锁定提示）。
2. **看到锁定提示后松手** → 面板保持锁定态，**继续说话仍被采集**（免手持核心场景）。
3. **轻点右⌘ 一次**（<10s）→ 停止并转写上屏（走既有链路，含低置信/空音频诊断）。
4. 锁定中再按住右⌘ ≥10s → 再次出现锁定提示，松手仍不停；随后轻点 → 上屏。
5. 录音中、锁定中按 Esc → 取消不上屏（面板提示「已取消录音（Esc）」）。
6. 按住 9s 松开 → 停止上屏（与改动前手感一致）。
7. ⌃⌥M latch：按一下开始、再按一下上屏——说话超 10s 不会自动锁定（latch 不计按住时长）。
8. 录音/锁定中按组合键（如 ⌘C）→ 取消录音并正常放行该组合键。

## 7. 红线遵守（W27 §9.5 + 本任务硬约束）

- **未动装机 bundle**：无 install-dev.sh / 无 open / 无 launch；构建产物只用于编译验证
  （xcodebuild 产物留在 macos/squirrel/build 构建树，绝不运行；lsregister 为 xcodebuild
  标准构建阶段，非拉起 app）。
- **零真实等待**：阈值/时长测试全走伪时钟（`W7PttLockMachine.clock` 注入，W27-fix 模式），
  `test_ptt_lock.swift` 全文无 `Thread.sleep`。
- **零 TCC**：新单测纯 Foundation 编译运行，不触麦克风/屏幕/辅助功能权限。
- 未触碰 `.github/`、`docs/RELEASE-NOTES*`、`config/ai*`。

## 8. 如实标注（未做/留待）

- **真机 IME 人工验收未执行**（用户机器输入法会话受损待重启；本任务按约束纯代码+单测交付），
  §6 清单留待装机（`~/Library/Input Methods/Squirrel-dev.app`）后逐条人工勾验。
- 锁定提示的「界面变化」以面板 preedit 文案通道实现（🔒/已锁定/可以松开按键了 + 与聆听态
  文案差异）；design-language 的 cyan/gold 发光脉冲等富视觉需自绘面板控件，超出本轮文案通道能力，
  以语义 token 映射记录（§3）。
- 勘误发现（未改动他轮产物）：`macos/w27/scripts/apply-w27.sh` 的 `SQ`/`PATCH` 相对脚本位置
  解析到 `macos/w27/squirrel` 与 `scripts/squirrel-w27.patch`，与实际路径（`macos/squirrel`、
  `macos/w27/squirrel-w27.patch`）不符，疑为潜伏路径 bug；W28 的 `apply-w28.sh` 已按正确层级
  解析并实测幂等，W27 脚本留待其轮次处置。
