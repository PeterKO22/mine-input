# W18 产品命名与显示名修复 交付报告

> 车道：W18 产品命名（Wave 4）｜日期：2026-11-04｜环境：macOS 27.0.1 arm64 / Xcode 27.2；Android SDK 37.0.0，emulator-5554 (API 34)
> 范围：`build/` `macos/`（含 `macos/w18/`、`macos/squirrel/` 工作树）`android/`｜命名决定 D15：**中文「提炼输入法」/ 英文 "Mine Input"**，不带 dev 后缀（dev 身份由 bundle id `im.rime.inputmethod.Squirrel.dev` 承担）
> 依据：build/W1-REPORT.md（dev 化改名清单）、build/squirrel-dev.patch、macos/W12-REPORT.md（勿破坏）、用户实测事故（IME 进程未拉起，见 §5）

---

## 0. 一句话结论

**显示名链路已从源头接通并程序化实证：输入源本地化名不再是裸 ID `im.rime.inputmethod.Squirrel.dev…`，TIS 运行时断言 + zh-Hans 显式解析断言「提炼输入法」全部 PASS（en "Mine Input"）；dev 改名唯一事实源 `build/squirrel-dev.patch` 已补 InfoPlist.xcstrings 本地化（pristine/reverse 双向套用验证过）；用户实测事故（重装后 macOS 不拉起 IME 进程）已用 install-dev.sh 强制门（open 拉起 + pgrep 存活检查 + IMK 端点日志）堵住并实测通过；Android 应用名/输入法名同步（aapt 断言 ALL PASS）；回归全绿：W7 回放 17/17、W7 挂点 22/22、W16 e2e 20/20。**

---

## 1. 问题与根因（实证）

**现象**（用户截图）：macOS「添加输入法」对话框里本输入法显示为裸 ID `im.rime.inputmethod.Squirrel.dev…` 而非名字。

**根因链**（实测定位）：上游 Squirrel 的输入源显示名来自 `resources/InfoPlist.xcstrings`（编译为各 lproj 的 `InfoPlist.strings`），查找键 = 输入源 ID：

| InfoPlist.strings 键（上游） | 值（zh-Hans） |
|---|---|
| `im.rime.inputmethod.Squirrel` / `.Hans` / `.Hant` | 鼠须管 / 鼠鬚管 |

W1 dev 化改名把 TISInputSourceID 改成 `im.rime.inputmethod.Squirrel.dev(.Hans/.Hant)`，但 xcstrings 的键没跟着改 → HIToolbox 按新 ID 查本地化名落空 → 退化显示裸 ID。TIS 探针（修复前，实测）：

```
input-source: id=im.rime.inputmethod.Squirrel.dev  localized-name=Squirrel  （回退 en CFBundleName）
input-source: id=im.rime.inputmethod.Squirrel.dev.Hans  localized-name=im.rime.inputmethod.Squirrel.dev.Hans   ← 裸 ID
input-source: id=im.rime.inputmethod.Squirrel.dev.Hant  localized-name=im.rime.inputmethod.Squirrel.dev.Hant   ← 裸 ID
```

---

## 2. (a) 修复：显示名从源头正确生成（zh-Hans「提炼输入法」/ en "Mine Input"）

**唯一事实源 `build/squirrel-dev.patch` 增补**（W1 dev 化改名脚本的补丁即改名的"源头"，fresh clone 套用后显示名即正确）：

1. `resources/InfoPlist.xcstrings`：键改名为 dev ID，值改 D15 名（en "Mine Input"，zh-Hans/zh-Hant「提炼输入法」）：

| 键（修复后） | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `CFBundleName` / `CFBundleDisplayName` | Mine Input | 提炼输入法 | 提炼输入法 |
| `im.rime.inputmethod.Squirrel.dev` | Mine Input | 提炼输入法 | 提炼输入法 |
| `im.rime.inputmethod.Squirrel.dev.Hans` | Mine Input | 提炼输入法 | 提炼输入法 |
| `im.rime.inputmethod.Squirrel.dev.Hant` | Mine Input | 提炼输入法 | 提炼输入法 |

（Hans/Hant 两个 mode 共用产品名——D15「统一、不带 dev 后缀」；简/繁由输入法内部方案区分。zh-Hant 直接用「提炼输入法」字形，与 D15 字面一致。）

2. `resources/Info.plist`：`CFBundleName` `Squirrel Dev` → `Mine Input`（dev 后缀不进显示名）。
3. `build/install-dev.sh` 输出同步显示名 + 缓存/重登提示（§5、§8）。

**补丁可复现性（实测）**：`git apply --reverse --check build/squirrel-dev.patch`（当前树=补丁后状态）✓；pristine worktree（干净 HEAD）`git apply --check` ✓。

**构建产物实证**（build-squirrel.sh 重跑 BUILD SUCCEEDED，编译出的 lproj InfoPlist.strings）：

```
[en]  CFBundleName => "Mine Input"   im.rime.inputmethod.Squirrel.dev(.Hans/.Hant) => "Mine Input"
[zh-Hans] CFBundleName => "提炼输入法"  im.rime.inputmethod.Squirrel.dev(.Hans/.Hant) => "提炼输入法"
[zh-Hant] 同 zh-Hans
```

解析链说明：kTISPropertyLocalizedName 由 HIToolbox 按「宿主应用上下文」查 InfoPlist.strings——裸 CLI 无 bundle 上下文时 CFBundle preferredLocalizations 固定回退 en（实测 `preferredLocalizations=["en"]`；给显式 zh 偏好则正确解析 `["zh-Hans"]`），故探针 TIS 名可能显示英文；**GUI（中文界面的系统设置对话框/菜单栏）应用上下文为 zh-Hans，解析出「提炼输入法」**——上游当年显示「鼠须管」即同一机制。探针对两种口径都断言（§3）。

---

## 3. (b) 程序化验证：TIS 探针 + 自动重试 + 重登提示

**交付**：`macos/w18/tis_probe.swift`（TIS API：TISCreateInputSourceList + kTISPropertyLocalizedName，另含 zh-Hans 显式解析断言）+ `macos/w18/w18-verify.sh`（三段断言，TIS 段自动重试 3 次，失败提示注销重登）。重装后实测输出（`bash macos/w18/w18-verify.sh`，VERIFY_EXIT=0）：

```
== [1/3] 静态断言：InfoPlist.strings 本地化链（键=.dev 输入源 ID）==
-- en.lproj --  [PASS] key …Squirrel.dev / .dev.Hans / .dev.Hant 存在   [PASS] 本地化值含 "Mine Input"
-- zh-Hans.lproj -- [PASS] 三个 key 存在   [PASS] 本地化值含 提炼输入法
-- zh-Hant.lproj -- [PASS] 三个 key 存在   [PASS] 本地化值含 提炼输入法

== [2/3] 运行时断言：TIS 探针 kTISPropertyLocalizedName ==
input-source: id=im.rime.inputmethod.Squirrel.dev.Hans  localized-name=Mine Input  bundle=im.rime.inputmethod.Squirrel.dev
input-source: id=im.rime.inputmethod.Squirrel.dev  localized-name=Mine Input  bundle=im.rime.inputmethod.Squirrel.dev
input-source: id=im.rime.inputmethod.Squirrel.dev.Hant  localized-name=Mine Input  bundle=im.rime.inputmethod.Squirrel.dev
[1/2] TIS PASS — 3 个 dev 输入源，本地化名含「提炼输入法」/ 'Mine Input'
[2/2] zh-resolve: preferredLocalizations(forPreferences: zh-Hans-CN,zh-Hans,zh-Hant,en) = ["zh-Hans"]
  CFBundleName => 提炼输入法  [PASS]
  im.rime.inputmethod.Squirrel.dev => 提炼输入法  [PASS]
  im.rime.inputmethod.Squirrel.dev.Hans => 提炼输入法  [PASS]
  im.rime.inputmethod.Squirrel.dev.Hant => 提炼输入法  [PASS]
[2/2] ZH PASS — zh-Hans 链路解析出「提炼输入法」（GUI 中文界面对话框/菜单栏同此值）

== [3/3] IME 进程拉起 + IMK 端口注册（W18 可输入性门）==
  [PASS] IME 进程存活: pid=26803
  …name=com.apple.inputmethodkit.setxpcendpoint
  [PASS] IMK XPC 端点已注册（com.apple.inputmethodkit.setxpcendpoint）
== RESULT: ALL PASS（静态 + TIS 运行时 + 进程/IMK）==
```

**缓存/重登提示（按要求内建）**：探针失败时打印「macOS 对输入源列表/显示名有缓存；重装后可能需注销重登后刷新」；w18-verify.sh 对 TIS 未刷新（rc=2/3）输出 `STATIC PASS / TIS STALE` 专档提示（注销重登后重跑 + 系统设置重新确认输入法）。实测窗口：某次重装后 TIS 清单被系统暂清（探针报未找到，见 §5 坑 2），`--register-input-source` + `--enable-input-source` 重跑后即恢复（上表即恢复后输出）。

---

## 4. 实测事故：重装后 macOS 不拉起 IME 进程（W18 中途用户报告，已修）

**事故**：重装 Squirrel-dev bundle 后，切换到该输入法时 macOS 没有拉起 IME 进程——输入源选中、按键掉空、完全无法输入；用户手动 `open` 启动后恢复（unified log 实证：19:30:45 手动拉起 pid 49137 → 19:31:27 `Activate Server` + `Inserting text` 正常）。

**根因方向**：`install-dev.sh` 原流程只 `--register-input-source`（跑完即退，不留进程）；`rm -rf + cp` 替换 bundle 后 LaunchServices/TextInput 的进程拉起注册失效，切换输入源时 macOS 不再 spawn IME。坑 2（连带发现）：替换**正在被使用/选中**的输入法 bundle 后，macOS 会把输入源暂时清出输入法清单（TIS 清单空、defaults 里 enabled 列表丢条目），`--register-input-source` 重新注册后清单恢复可能滞后（本次实测重跑注册+启用即恢复；个别窗口需注销重登）。

**对策（install-dev.sh，全部实测）**：
1. `[1/5]` 替换 bundle 前 `pkill` 旧 dev 进程（防旧进程占已删 inode、防 stale 二进制继续跑）；
2. `[3/5]` `--register-input-source` + `--enable-input-source`（尽力自动启用）+ 清单缓存提示；
3. `[4/5]` **强制门**：`lsregister -f` 刷新 LaunchServices → `open` 拉起 bundle → `sleep`×5 轮询 `pgrep` 存活检查 → 打印 IMK 端口注册日志（unified log `com.apple.inputmethodkit.setxpcendpoint`）；**进程不在则报错退出非零**，绝不留下"装完但打不了字"的状态。

实测输出（install-dev.sh，INSTALL_EXIT=0）：

```
== [1/5] 安装 …/Squirrel-dev.app ==
(已停止旧 dev IME 进程)
== [3/5] 注册并启用输入源（dev）==
Registered input source from file:///Users/you/Library/Input%20Methods/Squirrel-dev.app/
== [4/5] 拉起 IME 进程并检查存活（W18 强制门）==
IME 进程存活: pid=26803
2026-11-04 19:43:55.006 … Squirrel[26803] … name=com.apple.inputmethodkit.setxpcendpoint   ← IMK 端点注册
```

**人工验证步骤（给用户，GUI 手测；本环境禁 computer_use）**：
1. 跑 `bash build/build-squirrel.sh && bash build/install-dev.sh`——确认 `[4/5]` 打印「IME 进程存活」（不在会直接报错）；
2. 若「添加输入法」列表里看不到「提炼输入法」：注销重登（macOS 清单缓存），再在 系统设置→键盘→输入法 添加「提炼输入法」（Mine Input）；
3. 切到该输入法，TextEdit 里打 `w` 应上屏「人」——按键能上屏 = 进程/IMK 链路正常；若切换后无反应：`open ~/Library/Input\ Methods/Squirrel-dev.app` 拉起进程后重试；
4. 菜单栏输入法图标/输入源列表应显示「提炼输入法」（英文界面 Mine Input），不再是裸 ID。
（程序化部分 2/3+3/3 已覆盖：进程拉起 + IMK XPC 端点注册日志可见；真实 GUI 打字留人工。）

---

## 5. (c) Android：应用名/输入法名同步（assembleDebug + aapt 断言）

**改动**：`android/app/src/main/res/values/strings.xml`（默认/zh）`app_name`/`ime_name` → 「提炼输入法」；新增 `values-en/strings.xml` `app_name`/`ime_name` → "Mine Input"（subtype_label 补 en 译文）。`android/w18-label-check.sh` 一键断言（assembleDebug 后跑）：

```
== aapt dump badging（application-label 相关）==
package: name='com.mineinput.ime' versionCode='4' versionName='0.4.0-w16'
application-label:'提炼输入法'
application-label-en:'Mine Input'
  [PASS] application-label:'提炼输入法'
  [PASS] application-label-en:'Mine Input'
== ime_name 资源（aapt2 dump resources）==
    resource 0x7f010001 string/ime_name
      () "提炼输入法"
      (en) "Mine Input"
  [PASS] ime_name 含「提炼输入法」
  [PASS] ime_name(en) = 'Mine Input'
RESULT: ALL PASS
```

---

## 6. (d) 回归：既有测试仍绿

```
$ bash build/w7-replay-test.sh        # W7 回放（17 断言）
== 汇总: PASS 17 / FAIL 0 ==           REPLAY_EXIT=0
$ bash build/w7-test-rescore.sh       # W7 挂点（22 断言）
== 汇总: ALL PASS（failures=0） ==      RESCORE_EXIT=0
$ python3 android/w16-e2e.py          # W16 e2e（20 断言，emulator-5554）
=== 结果 ===  PASS=20 FAIL=0            E2E_EXIT=0
```

W16 e2e 诚实记录：前两次运行因模拟器 UI 状态残留各挂 1 项（一次 `via=no-ic`：EditText 焦点被抢；一次「找不到 EditText」：通讯录任务栈残留 PhotoPicker 页面）——均为 W16 报告遗留 7 的模拟器 input/UI 抖动，与本车道资源改名无关（e2e 不引用任何 label 文本；`am force-stop com.google.android.contacts` 清栈后 20/20）。W7/W12 侧测试（回放/挂点）两轮均绿，squirrel-w12.patch 依赖的源文件未动。

---

## 7. 交付物清单

| 路径 | 说明 |
|---|---|
| `build/squirrel-dev.patch` | dev 化改名唯一事实源：+InfoPlist.xcstrings 键改名/本地化（D15 名）+ CFBundleName=Mine Input（双向套用验证过） |
| `build/install-dev.sh` | 显示名/缓存提示 + W18 强制门（pkill 旧进程→lsregister→open 拉起→pgrep 存活检查→IMK 日志，失败退出非零） |
| `macos/w18/tis_probe.swift` | TIS 显示名探针（kTISPropertyLocalizedName + zh-Hans 显式解析断言，退出码语义化） |
| `macos/w18/w18-verify.sh` | 三段验证：静态 lproj / TIS 运行时（自动重试 3 次 + 重登提示）/ 进程+IMK 门 |
| `android/app/src/main/res/values/strings.xml` | app_name/ime_name=提炼输入法 |
| `android/app/src/main/res/values-en/strings.xml` | app_name/ime_name=Mine Input |
| `android/w18-label-check.sh` | aapt badging 应用名断言 |
| `macos/W18-REPORT.md` | 本报告 |
| `macos/squirrel/resources/InfoPlist.xcstrings` `Info.plist` | 树内同步改动（内容=squirrel-dev.patch 应用后状态；macos/squirrel 为第三方克隆不入本库） |

---

## 8. 遗留与 blocker（诚实）

1. **GUI 手测未执行**（本环境禁 computer_use）：「添加输入法」对话框/菜单栏实际渲染、切换后打字上屏，需用户按 §5 人工步骤复验；程序化侧（本地化链、TIS 名、进程+IMK 端点）已全覆盖。
2. **TIS 名的语言口径**：裸 CLI 上下文解析 en "Mine Input"（HIToolbox 按宿主应用上下文选 lproj，实测 preferredLocalizations 回退 en）；GUI 中文上下文解析「提炼输入法」（zh 链路已显式断言）。两种都是 D15 产品名，但探针里 TIS 行显示英文属预期，不是缺陷。
3. **重装正在使用的输入法会扰动 macOS 清单**（坑 2）：实测出现过「输入源被暂清出清单」的窗口，重跑注册+启用即恢复；个别情况需注销重登。这是 macOS 输入源缓存/生命周期的固有行为，已在 install-dev.sh 与 w18-verify.sh 输出里注明并给出恢复路径。
4. **Hans/Hant 共用显示名**（D15 统一命名的取舍）：输入源列表两项同名「提炼输入法」，若需区分可后续给 mode 名加「·简体/·繁体」后缀（改 xcstrings 即可，不动代码）。
5. **`--enable-input-source` 是尽力而为**：TIS 清单为空时为空操作；真正启用/添加仍可能需要用户在系统设置操作（macOS 不开放无头强制启用）。
