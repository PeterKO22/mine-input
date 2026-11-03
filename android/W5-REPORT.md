# W5 android · mine-input Android 基座 — 交付报告

> 日期：2026-11-04 ｜ 车道：W5 android ｜ 交付物：`android/` Kotlin IMS 骨架 + debug APK

---

## 1. 选型结论

**二选一 → 选「自研 Kotlin IMS 骨架」，不 fork Trime 出包。**

### 1.1 Trime 核实（先核实再选型）

| 核实项 | 结果 | 取证方式 |
|---|---|---|
| 许可证 | **GPL-3.0-or-later**（LICENSE 全文 674 行，GNU GPL v3 原文；源码 SPDX 头 `GPL-3.0-or-later`） | `curl raw.githubusercontent.com/osfans/trime/master/LICENSE`、README.md |
| 默认分支 | `develop`（HEAD `57feda7`）；另有 `main` | `git ls-remote` |
| 维护活跃度 | **活跃**：develop 分支最近提交 2026-11-01（距今 3 天），多条/日 | GitHub commits atom feed |
| 版本基线 | AGP 9.4.1、Kotlin 2.3.21、compileSdk 37、minSdk 21、versionName 3.3.14 | `raw .../develop/gradle/libs.versions.toml`、`app/build.gradle.kts` |
| 构建路径 | `make debug` → `./gradlew assembleDebug`；需 **Android SDK + NDK**、JDK 17、Python 3；`app/src/main/jni/` 下 **10+ 个 git submodule**（librime、librime-lua、librime-lua-deps、librime-octagram、librime-predict、snappy、rime-prelude/luna-pinyin/stroke/essay 等），librime-on-Android 即经 JNI 由 `jni/` CMake 原生构建产出 | `raw .../.gitmodules`、`Makefile`、README「Getting Started」 |
| 数据/方案对齐 | Trime 是 RIME 前端，schema 驱动（五笔/拼音可混输 ✅）；但 PTT、AI Hub、上下文引擎均无 | README / wiki 入口 |

### 1.2 为什么本阶段不 fork Trime（理由）

1. **原生构建链在本机缺失且代价高**：`~/Library/Android/sdk` 下 **无 NDK、无 CMake**（现状：build-tools 36/37、platforms android-37、emulator 36.5.11）；构建 Trime 需拉 NDK（GB 级）+ 10 余个 submodule（librime 树内还有 boost/marisa/opencc 等），CMake 原生全量编译小时级，且 GitHub API 本机已限流、`dl.google.com` 本机不可达，网络风险叠加。
2. **产品架构不是 RIME 前端贴皮**：需求 FR2（PTT 状态机 `idle→listening→transcribing→上屏`）、FR6（AI SPI `rescore/complete/correct/suggest/ingest`）、FR4/FR5（上下文/提词器）都是 Trime 没有的能力；在 Trime 内核上做这些等于把它的 RIME 生命周期当宿主负担。
3. **验收目标是「基座」**：QWERTY + 候选栏（五笔/拼音混合占位）+ PTT 大键 + 深色科幻视觉 + minSDK 29 + 可侧载 debug APK——纯 Kotlin/框架 API 骨架即可达成，且为后续引擎接线留出纯净落点。
4. **GPLv3 约束**（fork 路线的成本）：fork Trime 则衍生代码必须 GPLv3 同权开源；本项目个人分发场景可接受，但一旦混入自研闭源模块即违规。当前骨架不含任何 GPLv3 代码，许可证未定，保留选择权；**后续若采纳 Trime/librime 内核（同 schema 同词库路线），整个 Android 端衍生部分须转 GPLv3**，报告在此明示。

> 后续演进（留档，与技术方案 §2「壳 fork 不自研」不冲突）：骨架的引擎落点是 `MineImeService.candidates()`/`onLetter`（FR1 混输）与 `onPttDown/Up`（FR2）；W6+ 评估以 librime-android（JNI）替换占位引擎时，可走「librime 以 GPLv3 库链接 + 我方壳 GPLv3」或「整包 GPLv3」两条合规路径。

## 2. 自研骨架做了什么（android/ 目录）

- **工程**：Gradle 9.8.2 wrapper + AGP 9.4.1（AGP 9 内置 Kotlin，无需 kotlin.android 插件——实测报错后按官方指引移除）；`minSdk 29 / targetSdk 37 / compileSdk 37`；零第三方依赖（不引 androidx）。
- **`MineImeService`**（InputMethodService）：字母→composing→候选→上屏；空码顶字=关（FR1 默认值）；回车/空格/退格语义完整。接线点已注释标明。
- **`KeyboardView`**（自绘）：QWERTY 4 行 + 候选栏（五笔/拼音混合**占位**：演示码 `nh/wubi/py` 有示例候选，其余为 `码·五笔/拼音/混输` 占位，点选→上屏）+ **PTT 大键**（按下=听写中青光，松开=上屏占位文本，对齐技术方案 §6 状态机 UI）。
- **`DesignTokens`**：全部颜色常量直接取自 `design/design-language.md` §1（bg `#0E2924`、card `#18352F`、stroke `#2B4B44`、gold `#D4A857`、cyan `#388A83`、文字层级、数字 mono）；PTT=主按钮金实心/长按态青光、候选序号 gold mono、当前候选金填充微光（§5 A1/M1 映射）。
- **`MainActivity`**：启用输入法 → 选择输入法 引导（D12 侧载场景）。

## 3. 构建实测（输出要点）

```
$ export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=~/Library/Android/sdk
$ cd android && ./gradlew assembleDebug
> Task :app:compileDebugKotlin
> Task :app:packageDebug
> Task :app:assembleDebug
BUILD SUCCESSFUL in 10s
34 actionable tasks: 22 executed, 12 up-to-date
```

- **APK 产物**：`/Users/you/AITECreate/mine-input/android/app/build/outputs/apk/debug/app-debug.apk`（2,564,554 bytes）
- `aapt dump badging` 实测：`package: com.mineinput.ime versionCode=1 versionName=0.1.0-w5`；`sdkVersion:'29'`；`targetSdkVersion:'37'`；`launchable-activity: .MainActivity`；manifest 含 `android.view.InputMethod` service + `BIND_INPUT_METHOD`。
- 构建期仅 1 处代码改动即过编译：`InputMethodManager.ACTION_SHOW_INPUT_METHOD_PICKER` 为隐藏 API → 改用 action 字符串 `android.settings.SHOW_INPUT_METHOD_PICKER`。

## 4. 模拟器实测（Pixel_6_API_34，emulator 36.5.11）

| 步骤 | 实测结果 |
|---|---|
| `adb install` | `Success` |
| `ime enable` + `ime set` | `com.mineinput.ime/.MineImeService` 出现在 `ime list -s`，`settings get secure default_input_method` = 该服务 |
| 引导页启动 | `Displayed com.mineinput.ime/.MainActivity ... +115ms`，logcat 无 AndroidRuntime 崩溃 |
| 键盘绑定 | `dumpsys input_method`：`mBoundToMethod=true mInputShown=true` |
| **端到端打字**（通讯录「新建联系人」表单实测） | 点 `n`、`h` → 输入框 composing = `nh`；点候选① → 上屏 `你好·五笔`；**长按 PTT 1.5s** → 上屏 `〈语音转写占位〉` |
| 视觉核对（截图） | 深墨绿背景 + 深色键帽/细描边 + 金色「按住说话」大键 + 标准 QWERTY，与 design-language 一致 |

期间实测发现并修复一个真 bug：候选栏命中区只在 `onSizeChanged` 计算，数据更新不重排 → `updateState` 内补 `layoutKeys`（该 bug 是模拟器点选候选无效后定位的）。

## 5. 环境说明（按工作约定 5 注明）

- **JDK**：系统无 java_home 可见 JDK；使用 brew 的 `openjdk@17`（`/opt/homebrew/opt/openjdk@17`，17.0.19）作 `JAVA_HOME`，未新装。
- **网络**：`dl.google.com`（Google Maven）本机不可达 → `settings.gradle.kts` 依赖/插件仓库走**阿里云镜像**（google/central/gradle-plugin），并保留 google()/mavenCentral() 兜底；Gradle 发行版 `services.gradle.org` 可达但 wrapper 默认 10s 读超时 → 手动 curl 下载 `gradle-9.8.2-bin.zip`（sha256 校验 `21bd5da2…389607` 通过）预置进 `~/.gradle/wrapper/dists/`，`./gradlew` 可复现命中本地。
- **SDK**：`~/Library/Android/sdk` 复用既有（platforms android-37、build-tools 37.0.0、emulator 36.5.11），未新装组件。

## 6. 遗留项

1. 候选栏为**占位**：真实五笔86+拼音混输引擎（FR1，形码优先/拼音兜底/词频学习）待 W3/W6 接 `MineImeService` 的 `candidates()` 落点（librime 或自研）。
2. PTT 为**UI 状态机占位**：FR2 全管线（Silero VAD → SenseVoiceSmall → 标点 → 热词）未接，`onPttDown/Up` 留有落点；「松开→上屏 ≤1.5s」NFR2 未测。
3. 符号面板、候选翻页手势、长按删词等平台习惯交互未实现（骨架范围外，键位排布已按平台习惯）。
4. release 签名/侧载包（D12）：当前仅 debug（debug 签名），侧载分发包待里程碑收口时出 release。
5. 许可证待定：骨架当前无第三方代码、不涉 GPL；一旦接入 librime/Trime 内核须按 §1.4 转 GPLv3。
6. T1 机型未定（minSDK 29 基线先行）；真机（如侧载到实际设备）未测。
