# W32 · stable-signing-and-c1-optin — 稳定签名身份 + C1 读屏显式开关

目标（事故实锤对症）：根治「Squirrel-dev 想要录制此电脑的屏幕」反复弹窗——
(1) 稳定签名身份：ad-hoc cdhash 锚定 → 证书锚定，TCC 授权跨重装存活；
(2) C1 读屏显式开关：屏幕上下文默认 OFF，⌥M 开关打开才一次性请求授权，平时只探活，
    未授权跳过读屏（⌥M 状态行「读屏未授权」），打字/语音零权限请求。

## 1. 稳定签名身份（W32-a）

- **根因复述**：`codesign --sign -`（ad-hoc）→ `codesign -dr-` 显示
  `designated => cdhash H"…"`（本机构建产物实测即此形态，探针负例可复现）→ 每次
  重装/重建 cdhash 变 → tccd 对 kTCCServiceScreenCapture 判
  `Failed to match existing code requirement` → 同意/开关全部无效、反复弹窗。
- **修复**：自签名代码签名证书 **Mine Input Dev**（`scripts/make-dev-cert.sh`，幂等）：
  openssl 生成 CN=Mine Input Dev、RSA 2048/SHA-256、`extendedKeyUsage=codeSigning`、
  有效期 3650 天（10 年）→ 打包 PKCS#12（一次性口令）→ `security import` 进 login
  keychain（`-T /usr/bin/codesign`）。
- **install-dev.sh**：装机副本改签 `codesign --force --deep --sign "Mine Input Dev"`；
  找不到身份时**回退 ad-hoc 并大声警告**（横幅 + 修复命令）；签名后即打印
  `codesign -dr-` designated requirement 作为验收证据。
- **实测证据（scratch 副本，不装机不开 app）**：
  - 签名后：`designated => identifier "im.rime.inputmethod.Squirrel.dev" and
    certificate leaf = H"0de4c4899d461ddcd8014d1d4359f71016dcdf22"`——**identifier +
    certificate 锚，无 cdhash**；
  - 连续两次重签 designated requirement **逐字相同** → 授权可跨重装/重建存活；
  - 未签名构建产物：`designated => cdhash H"c3c387…"`（事故根因形态，探针负例）。
- **keychain 一次性手动动作**：首次用该证书签名可能弹「codesign 想使用密钥」→ 点一次
  **「始终允许」**（写入 docs/dev-signing-setup.md 与 INSTALL §1）。
- 坑记录（docs/dev-signing-setup.md）：自签证书 `find-identity -v`（valid only）会漏
  （`CSSMERR_TP_NOT_TRUSTED`，本机既有本地开发证书同状态，签名/锚定不受影响）；
  空口令 p12 `security import` 必失败；bash 变量紧邻中文需 `${}` 花括号。

## 2. C1 读屏显式开关（W32-b）

- **屏幕上下文默认 OFF**（机制保证，非口头约定）：`W12Settings.c1Screen` 默认 false
  （init/load/Info.plist 三层一致，`resources/Info.plist` W12C1Screen `<true/>`→`<false/>`）；
  运行时唯一开关 = ⌥M「读取屏幕内容以增强候选（需授权）」（持久 meta `c1_screen`，默认关；
  `W12Privacy.enableC1Screen/disableC1Screen/isC1ScreenEnabled`）。
- **⌥M 面板**（W20MemoryPanel 新增读屏行）：开关文案逐字「读取屏幕内容以增强候选（需授权）」；
  **打开开关 = CGRequestScreenCaptureAccess 一次性授权请求的唯一发起点**（弹系统 TCC
  确认框即授权确认，不加应用内弹窗）；状态行三态：「读屏：关（默认…）」/「读屏：开（已授权）」/
  「**读屏未授权**（系统设置→隐私与安全性→屏幕录制 允许「提炼输入法」；授权后 pkill+open 重启生效）」。
- **采集门禁**（W12ScreenGate + W12C1Collector）：真实读屏（`.screen` 源）前先
  `CGPreflightScreenCaptureAccess()` 探活（不弹窗）——未授权 → 跳过读屏
  （skipped 逐字 `读屏未授权（CGPreflightScreenCaptureAccess=false；跳过读屏，绝不自动发起授权请求）`），
  **绝不自动 CGRequest**；开关关 → 连探活都不做（autoclosure 短路，零权限交互）。
  文件源（探针等价帧）不涉 TCC 门禁，脚本化实测链路保持可用。
- **打字/语音默认零权限请求**：按键/PTT/转写路径 CGRequest 调用数恒 0（单测断言）；
  麦克风仍走 W26 既有语义（PTT 实际录音才触发），不受本开关影响。
- **SuggestContext 屏幕上下文同门禁**：开关关 → `screenText` 恒空（即使环内有旧内容）；
  关闭即清屏幕上下文环（W12Privacy.disableC1Screen → ScreenTextContext.clear）。
- **CLI 查询/设置**（开关必须带检查路径）：`w12ctl privacy c1screen on --confirm|off|status`、
  `w12ctl privacy status` 显示读屏开关状态（CLI 不发起 TCC 请求——授权请求只在 ⌥M 开关）。

## 3. 单测/探针（全部实测输出）

| 项目 | 命令 | 结果 |
|---|---|---|
| W32 门禁单测（伪时钟零 sleep、mock 授权、零 TCC） | `bash build/w32-test-screen-gate.sh` | **51/51 ALL PASS** |
| w12 无回归 | `cd macos/w12 && swift test` | **20/20**（0 失败；W27InputEventTests 夹具显式置 c1Screen=true——套件即读屏链路） |
| context 无回归 | `cd context && swift test` | **40/40**（MemoryCore 21 + ContextCore 19，0 失败） |
| w20 无回归 | `cd macos/w20 && swift test` | **15/15**（0 失败） |
| w27-e2e 注入探针（含新增 W32 场景 0） | `cd macos/w12 && swift run w12ctl w27-e2e` | **ALL PASS** |
| 全 app 构建 | `bash build/build-squirrel.sh` | **BUILD SUCCEEDED**（产物 Info.plist：W12C1Screen=false、W12C1Enabled=false） |
| 签名探针（正例） | `bash macos/w32/scripts/w32-sign-probe.sh <scratch 签名副本>` | **ALL PASS**（identifier + certificate 锚，非 cdhash） |
| 签名探针（负例） | 同上指向未签名构建产物 | **FAIL 如预期**（cdhash 锚检出） |

门禁单测覆盖：真值表（开关×授权 4 象限）/ autoclosure 短路（开关关零探活）/ 状态行
三态（未授权含「读屏未授权」逐字）/ 默认态打字零 preflight 零 request 零入库 / 未授权
跳过读屏（request 恒 0）/ 授权后读屏入库（摘要不落原文）/ 伪时钟防抖集成（窗内合并、
出窗恢复）/ 开关中途开↔关（默认 OFF 机制保证 + SuggestContext 同门禁）/ requestAccess
唯一发起点（拒绝后不自动重请求）/ 文件源不涉 TCC 门禁 / 显式开关语义（不显式确认拒绝开启）。
全程注入伪时钟（collector.clock）与 mock 授权（W12ScreenAccess），零 Thread.sleep、零真实 TCC。

## 4. 手工验收清单（装机留待；本任务不 install 不 open）

> 前置：`bash scripts/make-dev-cert.sh`（已实测跑通、幂等）→ `bash build/build-squirrel.sh`
> → `bash build/install-dev.sh`（以 Mine Input Dev 签名；首次签名弹「codesign 想使用密钥」
> → 点**「始终允许」**一次）。

**A. 签名验收（授权跨重装存活）**
1. `bash macos/w32/scripts/w32-sign-probe.sh` → ALL PASS（designated 含 identifier +
   certificate 锚，无 cdhash）。
2. 重装一次（`bash build/install-dev.sh`）→ 再跑探针 → designated requirement **逐字不变**
   （同证书重签锚定稳定）。

**B. 最终授权流程（录屏授权一次性、不再弹窗风暴）**
1. `tccutil reset ScreenCapture im.rime.inputmethod.Squirrel.dev`（清旧记录）；
2. ⌥M 打开「读取屏幕内容以增强候选（需授权）」→ **弹一次**「Squirrel-dev 想要录制此电脑的屏幕」；
3. 系统设置 → 隐私与安全性 → 屏幕录制 → 允许「提炼输入法」（Mine Input）；
4. 重启进程：`pkill -f "Squirrel-dev.app/Contents/MacOS/Squirrel" && open ~/Library/Input\ Methods/Squirrel-dev.app`
   （TCC 进程启动时读取——不重启则授权不生效，这是 W27「同意了也没用」的另一半根因）；
5. 再打字 → **不再弹窗**，⌥M 状态行「读屏：开（已授权）」，候选开始吃到屏幕上下文。

**C. 负例（默认零权限）**
1. `tccutil reset ScreenCapture im.rime.inputmethod.Squirrel.dev` 后**不**动开关，连续打字
   → **零弹窗**（默认 OFF：连 preflight 都不发起请求）；
2. 开关打开但第 2 步弹窗点「取消」→ 打字**不弹窗**、不采集，⌥M 状态行显示「读屏未授权」；
   再打字仍不弹（绝不自动重请求；授权须用户去系统设置）；
3. 开关关闭 → 立即停读屏，⌥M 状态行回「读屏：关（默认…）」；
4. 密码框（安全输入）→ 恒零采集不可关（既有 W27 语义不回归）。

## 5. 如实标注 / 边界

- **未装机、未真机点弹窗**：A/B/C 全部留待装机验收（红线：本任务不 install 不 open）；
  签名与门禁机制均在构建产物/scratch 副本上实测（签名探针正负例、51/51 门禁单测）。
- 自签证书 `CSSMERR_TP_NOT_TRUSTED`（未加信任）：codesign 签名与 designated requirement
  锚定已实测不受影响；TCC 按 requirement 匹配授权。若装机后 tccd 仍判不匹配，升级动作是
  `security add-trusted-cert` 将证书置信（会弹 keychain 确认）——留作 B 步失败时的后备。
- `CGRequestScreenCaptureAccess` 在授权已被系统「拒绝」后不会重复弹窗（系统级语义），
  状态行如实显示「读屏未授权」并指路系统设置；「一次性」指每次开关打开动作至多一次请求。
- 读屏子开关与 C1 总开关为两层：总开关（C1 屏幕/语音，默认关）+ 读屏开关（默认关），
  任一关都不读屏；语音 asr_digest 不受读屏开关影响（无权限请求变化）。
- 产物 Info.plist W12C1Screen=false 已进构建产物（`PlistBuddy` 实测打印 false）。

## 6. 文件清单

- `scripts/make-dev-cert.sh`（新）：证书生成+导入，幂等。
- `docs/dev-signing-setup.md`（新）：setup 文档（含 keychain「始终允许」、三个实测坑）。
- `INSTALL.md` / `INSTALL.zh-CN.md`：§1 增加证书步骤（step 4）。
- `build/install-dev.sh`：装机副本改证书签名（找不到身份回退 ad-hoc + 大声警告）+
  designated requirement 打印。
- `macos/w12/src/W12ScreenCapture.swift`：+W12ScreenAccess（preflight/request 注入）+
  W12ScreenGate（纯门禁 + 状态行文案）。
- `macos/w12/src/W12Config.swift`：c1Screen 默认 false（init/load）+ W12Privacy
  enableC1Screen/disableC1Screen/isC1ScreenEnabled + screenSwitchTitle。
- `macos/w12/src/W12C1Collector.swift`：isScreenEnabled、screenAccess/captureImageOverride
  注入、`.screen` 门禁、makeSuggestContext 同门禁。
- `macos/w20/src/W20MemoryStore.swift`：+W20ScreenContextControl 协议。
- `macos/w20/src/W20MemoryPanel.swift`：⌥M 读屏行（文案逐字「读取屏幕内容以增强候选（需授权）」）。
- `macos/w20/src/W20SquirrelGlue.swift`：+W20SquirrelScreenControl（request 唯一发起点）。
- `macos/squirrel/resources/Info.plist`：W12C1Screen false（记录补丁 macos/w32/squirrel-w32.patch
  + apply-w32.sh 幂等实测）。
- `macos/w12/tests/test_screen_gate.swift` + `build/w32-test-screen-gate.sh`（新）：51/51。
- `macos/w12/tools/w12ctl/main.swift`：w27-e2e 增 W32 场景 0 + `privacy c1screen` 查询/设置。
- `macos/w12/tests/W12CoreTests/W27InputEventTests.swift`：夹具显式 `W12Settings(c1Screen: true)`
  （读屏默认 OFF 后的显式 opt-in，20/20 不变）。
- `macos/w32/scripts/w32-sign-probe.sh`（新）：装机后签名验收探针。
