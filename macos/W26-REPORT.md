# W26-REPORT — voice-mic-perm：修复 macOS 语音输入静默失聪

日期：2026-11-07 ｜ 范围：macos/squirrel 构建链、macos/w7、build/*、macos/w26
验收口径：装机 InfoPlist 证据 + replay 17/17 不回归 + 音频注入验证到 `w7CommitVoiceText` 入口（真人右⌘→说话→上屏未实测，如实标注）。

## 1. 根因与修复

**根因（已定，勿再排查）**：装机 App（`~/Library/Input Methods/Squirrel-dev.app`）的 `Contents/Info.plist`
缺 `NSMicrophoneUsageDescription`。macOS 对缺该键的进程**静默拒绝**麦克风采集（tccd 零记录、无弹窗），
`AVAudioEngine` 采集恒为全零静音 → PTT 永远拿到空音频。其余环节（voice/mic/replay_test.py 17/17、
ptt_daemon 常驻、JSON 协议）实测健康。

**修复**：
1. `resources/Info.plist` 补 `NSMicrophoneUsageDescription`＝「语音输入需要使用麦克风（按住右 Command 说话，松开上屏）」，
   以 `build/squirrel-w26.patch` 幂等落地，挂进 `build/build-squirrel.sh`（在 squirrel-linear.patch 之后）。
2. 诊断分支加固（`macos/w7/src/W7PttController.swift`）：PCM **全零或极短（<0.25s@16k）**时提示
   「未收到声音，请检查麦克风权限」，不再误导成「没听清，请重说」；「没听清」只留给有声但低置信的场景。
3. 加固顺手项：W26Probe 采集 start 走后台队列（首次授权弹窗阻塞 `engine.start()` 时不冻结 IME 主线程）；
   证据行 nonce 传值防串号；`build/install-dev.sh` 增加 PlistBuddy **硬自检门**（缺键即中止安装）。

## 2. 改动清单

| 文件 | 改动 |
|---|---|
| `build/squirrel-w26.patch`（新） | Info.plist 补 NSMicrophoneUsageDescription + SquirrelApplicationDelegate.addObservers() 注册 W26Probe 监听；两个 hunk 均避开 w12/w20 改动区，任何补丁顺序可套（§4 实测） |
| `build/build-squirrel.sh` | 幂等套用 squirrel-w26.patch（linear 之后）；产物自检 grep 加 NSMicrophoneUsageDescription |
| `build/install-dev.sh` | [1/5] 新增 PlistBuddy 自检门：缺 NSMicrophoneUsageDescription 即 exit 1（§3） |
| `macos/w7/src/W7PttController.swift` | 空音频诊断 `emptyAudioReason`；`processPCM` 统一决策链（PTT 与注入共用）；W26Probe 注入探针（token 文件安全门，未武装完全惰性、正常 PTT 零落盘） |
| `macos/w26/w26_probe.swift`（新） | 注入/采集验收探针（swiftc + Carbon，w18 tis_probe 同款惯例） |
| `macos/w26/w26-voice-probe.sh`（新） | 探针包装：装机证据→会话准备→5 案例→清理还原；日志 build/logs/w26-voice-probe.log |

**探针安全门**：W26Probe 仅在 `~/Library/Rime-mine-dev/w7-probe.enabled` 存在时响应触发（探针测试窗口内创建、
结束删除，wrapper 另有 trap 兜底）；默认态任何本地进程发分布式通知都被直接忽略。证据：`~/Library/Rime-mine-dev/w7-probe.log`。

## 3. 验收实证

### 3.1 InfoPlist 证据（硬验收项）

```
$ /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' \
    "$HOME/Library/Input Methods/Squirrel-dev.app/Contents/Info.plist"
语音输入需要使用麦克风（按住右 Command 说话，松开上屏）      # exit 0
```

安装自检门输出（`build/logs/w26-install4.log`，install-dev.sh [1/5]）：

```
== [1/5] 安装 /Users/aitetot/Library/Input Methods/Squirrel-dev.app ==
  ...
NSMicrophoneUsageDescription = 语音输入需要使用麦克风（按住右 Command 说话，松开上屏）
== [2/5] 部署并验证 RIME 用户目录 /Users/aitetot/Library/Rime-mine-dev ==
...
== [4/5] 拉起 IME 进程并检查存活（W18 强制门）==
IME 进程存活: pid=433
```

（W18 强制门同过；codesign ad-hoc 重签名：`Signature=adhoc, Identifier=im.rime.inputmethod.Squirrel.dev`。）

### 3.2 诊断分支加固（W26Probe 注入，真机 IME 进程内实测）

```
-- 案例 2：注入 1s 全零 PCM → 期望空音频诊断提示 --
    {"event":"status","source":"probe","text":"未收到声音，请检查麦克风权限",...}
  [PASS] 全零 PCM → 「未收到声音，请检查麦克风权限」
-- 案例 3：注入 0.1s 极短杂音 → 期望同为空音频诊断 --
  [PASS] 极短 PCM → 「未收到声音，请检查麦克风权限」
```

「没听清，请重说」现仅出现在有声但 `low_confidence`/空文本分支（真没听清），与空音频（查权限）严格区分。

### 3.3 音频注入 → w7CommitVoiceText 入口（验收替代路径，未真人实测）

注入 `voice/audio/s1.wav`（采集同款 16k mono PCM16，全程内存）走真机 IME 的与 PTT **完全同一条**
决策链（空音频诊断 → ptt_daemon 管线 → 低置信门 → commit）：

```
-- 案例 1：注入 s1.wav → 期望到达 w7CommitVoiceText 入口 --
    {"event":"commit","text":"今天天气不错，我们下午去公园散步吧。","source":"probe","controller":false,...}
  [PASS] s1 注入 → w7CommitVoiceText 入口（commit 事件） — controller=0
  [PASS] s1 转写逐字命中 W2 期望 — text=今天天气不错，我们下午去公园散步吧。
== W26 注入探针汇总: PASS 4 / FAIL 1 ==   （FAIL 项=真采集案例，见 §3.4）
```

证据文件 `~/Library/Rime-mine-dev/w7-probe.log` 共 4 条 `commit` 事件（4 轮重跑均逐字命中 W2 期望）。
`controller:false` 语义：本机无活动输入会话挂载（合成按键需辅助功能权限，未授予），故 w7CommitVoiceText
**入口已达、调用已发**，但客户端上屏目标为空——「文本落进真实文档」这一步未实测（见 §5）。

### 3.4 真实麦克风样本（根因修复的行为级实证）

真机 IME 进程内 `AVAudioEngine` 采集实测（W26Probe 案例 4/5）：

```
{"event":"mic","frames":19045,"peak":452,"rms":0.0038,"silent":false}   # 1.2s 真实环境声
{"event":"mic","frames":19045,"peak":616,"rms":0.0056,"silent":false}   # 复测同样非零
{"event":"mic","frames":108568,"transcribe":true}                       # 6.8s 连续真实采集
```

- **非零采集 = 根因症状消失**：修复前该路径恒为全零静音；现拿到真实环境底噪（peak 452/616）。
- **系统麦克风授权弹窗已实证出现**：首次采集时 `engine.start()` 阻塞在 TCC 授权流程上约 83s，
  用户点「允许」后立即放行并采集到非零音频——即「首次使用弹授权框，允许后即通」的机制在真机复现
  （与验收预期「用户首次按右⌘会看到系统麦克风授权弹窗」同一 TCC 请求路径，见 §5 坑 1）。
- 案例 5（外放 s1.wav + 真实采集 → 转写 → commit）在弹窗批准轮因外放错过采集窗口（时序被弹窗阻塞打乱）
  得 `no_speech_detected`→「没听清」；时序修复后复跑又被**重签名重置授权**卡在待点弹窗（§5 坑 1），
  未能拿到「真实人声/外放声 → commit」的完整样本。此项**如实标注未完成**，其余全绿。

### 3.5 replay_test 不回归

```
$ bash build/w7-replay-test.sh
== 汇总: PASS 17 / FAIL 0 ==
```

17/17 PASS（s1–s5+multi 逐字、静音/空/噪音低置信、热词纠偏、不落盘、常驻多轮），无回归。

### 3.6 补丁可复现/幂等（两种套用顺序实测）

mini 树（HEAD + 仅涉事两文件）上模拟：

```
order A: dev → w7 → linear → w26 → w12 → w20   全部 applied OK，w26 --reverse --check OK
order B: dev → w7 → w12 → w20 → w26            全部 applied OK，w26 --reverse --check OK
build-squirrel.sh 重跑：build/squirrel-w26.patch already applied（幂等）
```

hunk 锚点刻意选 `NSPrincipalClass` / `addObservers()` 尾部（w12/w20 不触碰），先套后套上下文均一致。

## 4. 探针输出（完整会话）

`bash macos/w26/w26-voice-probe.sh`（日志 `build/logs/w26-probe-*.log`）5 案例：
注入 s1（commit 入口）、全零、极短、真采集 1.2s、外放+真采集 6.5s。
最终轮：案例 1–3 PASS；案例 4 因待点授权弹窗 120s 无采集事件 FAIL（探针正确提示）；案例 5 按设计跳过。

## 5. 未完成项 / 坑（诚实标注）

1. **重签名重置 TCC 麦克风授权（坑，已定位）**：`install-dev.sh` 的 ad-hoc `codesign --force` 每次改变
   cdhash，macOS 视为「被修改的 App」重置麦克风授权 → 每次重装后首次采集再弹授权框、`engine.start()`
   阻塞至用户点击。对最终用户只发生在首次（其后正常使用不再重装），但自动化复跑需人工点一次弹窗。
2. **真人实测未做**：右⌘（按住）→ 真人说话 → 文本落进真实文档，需真人操作；
   合成按键/上屏复核需「辅助功能」权限（本 agent 进程未授予，`prime-keystroke: FAILED`）。
   剩余人工步骤（一次性）：
   - 点掉屏幕上待决的「麦克风」授权弹窗（或 系统设置→隐私与安全性→麦克风 打开「提炼输入法」——设置页已打开）；
   - `bash macos/w26/w26-voice-probe.sh` 复跑（预期 案例 4/5 转 PASS，含外放→真实采集→commit 入口）；
   - 切到「提炼输入法」，TextEdit 按住右⌘说话松开，确认文本上屏。
3. **TCC.db 不可读**（无完全磁盘访问），「系统设置→麦克风 出现条目」无法程序化截图/断言
   （cua-driver 无屏幕录制权限，安全弹窗 AX 树为空）——以 §3.4 的行为证据（弹窗阻塞→批准→非零采集）替代。
4. **TIS 列表暂清（W18 已知）**：CLI 侧 `TISSelectInputSource` 偶发找不到 dev 输入源；
   `--register-input-source` + `--enable-input-source` 重跑后 tis-probe 即恢复
   （`im.rime.inputmethod.Squirrel.dev.Hans => 提炼输入法 [PASS]`）。与 W26 无关，沿用 W18 处置。
5. **已知遗留（W26 记录，未修）**：真人 PTT 首次右⌘ 时若授权弹窗未决，`startCapture()` 在主线程的
   `engine.start()` 同样阻塞至用户点击（W7 期既有行为）；W26Probe 路径已改后台队列，PTT 路径的
   同款加固留给后续 lane。

## 6. 复跑命令

```bash
bash build/build-squirrel.sh      # 幂等套补丁 + 重构建（含 squirrel-w26.patch）
bash build/install-dev.sh         # 装机 + PlistBuddy 自检门 + W18 进程门
bash build/w7-replay-test.sh      # 17/17 回归
bash macos/w26/w26-voice-probe.sh # 注入/采集验收（token 自清理）
```
