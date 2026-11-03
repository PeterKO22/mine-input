# W14 android-voice · Android 端 PTT 离线语音转写输入 — 交付报告

> 日期：2026-11-04 ｜ 车道：W14 android-voice ｜ 范围：只动 `android/`
> 对齐：FR2（PTT 全管线）/ NFR2（松开→上屏 ≤1.5s）/ NFR5（模型百 MB 级懒加载常驻）；
> 管线语义对齐 `voice/W2-REPORT.md` + `voice/mic/README.md`；接进 W5 骨架 commit 通道。
> 环境：macOS 27.0.1，emulator-5554（Pixel_6_API_34，**arm64-v8a**），JAVA_HOME=/opt/homebrew/opt/openjdk@17。

## 0. 结论摘要

- **(a) sherpa-onnx v2.0.1 Android 预编译集成完成**：GitHub Releases `sherpa-onnx-2.0.1.aar`（49,441,341 B，含 arm64-v8a/armeabi-v7a/x86/x86_64 全 ABI 的 `libsherpa-onnx-jni` + `libonnxruntime`），经本地 Maven 仓库引入（AGP 9 不支持直接 .aar 文件依赖）。**SenseVoiceSmall int8 模型首用下载式，不进 APK**，下载→SHA256 校验→纯 Java 解压→逐文件再校验，全部实测通过（§2）。
- **(b) PTT 长按→录音→分段转写→候选区滚动→松开上屏全链路跑通**：AudioRecord 16k mono PCM16 纯内存缓冲；VAD 流式切段、完成段带 0.25s pre-roll 即时转写；**滚动文本 == 上屏文本**（同一份段转写，松开不再重转写）；上屏走 W5 `commitText` 通道（实测 `via=input-connection` 进真输入框）。
- **(c) 取消（滑出/返回键）与失败提示实测通过**：滑出 PTT 键、返回键均取消且不上屏；静音/低置信 → 「请重说」不瞎猜上屏（与 mic README 低置信启发式同源）。hotwords.txt 两级热词（显式别名 + 同音纠偏）实测触发 `同音替换: 可送→可颂`（与 W2 PoC 完全一致）。
- **(d) DebugReceiver 测试钩子确定性可断言**：`w14_model / w14_asr / w14_ptt / w14_rec / w14_status`；`android/w14-e2e.py`（adb 脚本）推样音→触发→logcat 断言→上屏记录，**最终 PASS=32 FAIL=0，exit 0**（§5）。
- **NFR2**：松开→上屏（final_ms，流式终稿）实测 **1–2ms**（27.6s 多段样音也一样，与音频时长解耦）；单句全管线 92–616ms；听写中滚动按 VAD 段粒度刷新（多段样音 4 次滚动更新）。**NFR5**：模型 239MB 磁盘常驻（int8，百 MB 级），懒加载（首次按 PTT / 设置页按钮触发下载），引擎常驻内存加载 0.5–3.3s 一次性。

## 1. 交付物清单（android/ 内）

| 文件 | 作用 |
|---|---|
| `fetch-deps.sh` | 拉取 sherpa-onnx AAR + 解压 jar，SHA256 钉死校验（外部预编译不进 git） |
| `local-repo/com/k2fsa/sherpa/sherpa-onnx/2.0.1/` | 本地 Maven 仓库：AAR（fetch 获取）+ POM（进 git） |
| `app/libs/commons-compress-1.26.2.jar` + `commons-io-2.16.1.jar` | tar.bz2 纯 Java 解压（Android toybox 无 bunzip2，见 §6 坑 2） |
| `app/src/main/java/com/mineinput/ime/voice/ModelManager.kt` | 首用下载 + SHA256 校验 + 解压 + 产物逐文件校验 |
| `voice/AsrEngine.kt` | sherpa-onnx 封装：SenseVoice int8 + Silero VAD；全管线 `transcribe` + 流式 `LiveSession`（带 pre-roll 切片） |
| `voice/Hotwords.kt` | hotwords.txt 解析 + 两级热词纠偏 + 标点串合并（W2 apply_hotwords 同源） |
| `voice/VoiceInput.kt` | PTT 会话编排（PttSession）+ 上屏/记录（W5 commit 通道 + W11 voice_session）+ WAV 解析 |
| `voice/PttRecorder.kt` | AudioRecord 16k mono → 内存缓冲 → 流式喂段 → 滚动回调 → commit/cancel |
| `voice/W14Debug.kt` | (d) 测试钩子（w14_* 命令，logcat tag=W14） |
| `app/src/main/assets/voice/hotwords.txt` | 默认热词表（= voice/poc/hotwords.txt，首用播种到 filesDir 可编辑） |
| `app/src/main/assets/voice/pinyin.txt` | 逐字拼音表 20,924 条（pypinyin 默认读音生成，同音纠偏用） |
| `KeyboardView.kt`（改） | 候选区滚动转写覆盖层、滑出取消手势（红色「松开取消」）、失败红字提示 |
| `MineImeService.kt`（改） | onPttDown/Up/Cancel 真管线、返回键取消、`commitVoiceText` 上屏通道 |
| `DebugReceiver.kt`（改） | w14_* 转发（仅 debug 包）；`AndroidManifest.xml` 加 RECORD_AUDIO |
| `MainActivity.kt`（改） | 「③ 下载/校验语音模型」「④ 授权麦克风」入口 |
| `w14-e2e.py` | adb 验收脚本（32 项断言，输出见 §5） |
| `app/build.gradle.kts` / `settings.gradle.kts` / `.gitignore`（改） | 依赖接入、版本 0.3.0-w14、外部产物 gitignore |

## 2. (a) sherpa-onnx 集成 + 模型首用下载（SHA256 记录）

### 2.1 预编译集成选型

- sherpa-onnx **v2.0.1** GitHub Releases 预编译：`sherpa-onnx-2.0.1.aar`（`classes.jar` 的 `com.k2fsa.sherpa.onnx` Kotlin API + `jni/<abi>/libsherpa-onnx-{jni,c-api,cxx-api}.so` + `libonnxruntime.so` × 4 ABI）。SHA256：`a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7`。
- **AGP 8+ 不支持直接 .aar 文件依赖** → 本地 Maven 仓库布局（`android/local-repo/`，POM 进 git、AAR 由 `fetch-deps.sh` 获取校验），`settings.gradle.kts` 加 `maven(url = uri("${rootDir}/local-repo"))`。AAR 内 `OfflineRecognizer(null, config)`（文件路径模式）与 `Vad(null, config)` 经 javap 反编译核实后接入。
- 解压用 jar（SHA256 钉死）：`commons-compress-1.26.2.jar` `9168a03141d8fc7eda21a2360d83cc0412bcbb1d6204d992bd48c2573cb3c6b8`、`commons-io-2.16.1.jar` `f41f7baacd716896447ace9758621f62c1c6b0a91d89acee488da26fc477c84f`。
- 复现：`bash android/fetch-deps.sh`。

### 2.2 模型清单（首用下载，不进 APK；与 W2 报告 §3 同一产物）

| 产物 | 用途 | 下载源 | SHA256 |
|---|---|---|---|
| `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2`（163,002,883 B） | SenseVoiceSmall int8 归档 | GitHub Releases `asr-models` | `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e` |
| ↳ 解出 `model.int8.onnx`（239,233,841 B） | ASR 转写（int8） | 同上（解压后逐文件校验） | `c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51` |
| ↳ 解出 `tokens.txt`（315,894 B） | 词表 | 同上 | `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc` |
| `silero_vad.onnx`（643,854 B） | VAD 切段 | 同上 tag | `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` |

- **下载链路实测**（模拟器内真下载）：GitHub Releases 直连畅通（W2 同结论；HF/hf-mirror 不可用、ModelScope 无 sherpa-onnx 官方导出——已探测 `record not found`，故与 W2 同源走 GitHub）；163MB 归档 ~70s 下完（约 2.3MB/s）。
- **校验流**：流式下载边下边算 SHA256 → 归档校验不过即弃（`.part` 不落定）→ 解压 `model.int8.onnx`/`tokens.txt` → **逐文件再校验** → 写 `INSTALLED` 标记。模型落 `filesDir/voice-models/`（应用私有目录）。
- **首用触发**：首次按 PTT / MainActivity「③ 下载/校验语音模型」按钮 / `w14_model` 钩子；PTT 在模型未就绪时提示「首次使用需下载语音模型」并自动后台下载。
- 实测 log（节选）：

```
W14: MODEL_DL begin name=silero_vad.onnx url=https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx expect_bytes=0 sha256=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6
W14: MODEL_DL done name=silero_vad.onnx bytes=643854 sha256=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6
W14: MODEL_DL done name=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2 bytes=163002883 sha256=7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e
W14: MODEL_EXTRACT begin sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
W14: MODEL_EXTRACT file=.../tokens.txt bytes=315894
W14: MODEL_OK installed=true model.int8.onnx=239233841,tokens.txt=315894,silero_vad.onnx=643854
W14: ENGINE_LOADED load_ms=508 model=239233841 tokens=315894 vad=643854
```

## 3. (b) PTT 管线（对齐 voice/mic/pipeline.py 语义）

```
AudioRecord(VOICE_RECOGNITION, 16k mono PCM16)
  → 内存缓冲（会话级，转写完/取消即弃，音频不落盘）
  → 0.5s 块喂 Silero VAD（threshold 0.5 / min_silence 0.5s / min_speech 0.3s / window 512）
  → 完成段切片 [start-0.25s, end+0.25s]（pre-roll，W2 踩坑 3 同解）
  → SenseVoiceSmall int8 转写（use_itn 自带标点）→ 标点串合并
  → hotwords.txt 纠偏（显式别名 + 同音窗口）→ 候选区滚动回传
  → 松开：收尾段 + 组装 → 低置信判定 → W5 commit 通道上屏 + W11 voice_session 记录
```

- **滚动文本 == 上屏文本**：每段转写就是最终文本的组成，松开只补收尾段（本设计把「松开→上屏」与音频时长解耦，NFR2 达标的根因；首版曾在松开时重跑整段 ASR，27.6s 样音实测 1797ms 超 NFR2，重构后 final_ms=1ms）。
- **分段与滚动**：多段样音 benchmark_multi.wav（27.6s）VAD 切 4 段、逐段即时转写、候选区滚动 4 次刷新（滚动层在候选栏位置显示尾部跟随文本，听写中青色描边）。
- **上屏**：`MineImeService.commitVoiceText` → `currentInputConnection.commitText(text, 1)`（W5 commit 通道）+ W11 `voice_session` 事件（C0 同意 + 熔断门控，与 W11 既有上报同路）。
- **转写正确性**（样音 = W2 的 say -v Tingting 16k mono，热词开）：

| # | 原文 | 设备转写（SherpaOnnx 实测） | 一致 |
|---|---|---|---|
| s1 | 今天天气不错，我们下午去公园散步吧。 | 今天天气不错，我们下午去公园散步吧。 | ✅ 逐字 |
| s3 | 我在星巴克点了一杯拿铁和一个可颂面包。 | 我在星巴克点了一杯拿铁和一个可颂面包。 | ✅（热词修正后） |
| benchmark_multi（5 句连读 27.6s，4 段拼接） | 5 句全文 | 与 W2 §5 整段连读转写全文**逐字相同** | ✅ |

- **延迟**（emulator-5554 arm64）：单句全管线 s1 158–616ms（vad 14–76 + asr 74–332 + 热词 1–3）、s3 89–150ms；多段 27.6s 流式喂段总 571ms、**松开→上屏 final_ms=1ms**；引擎常驻加载 0.5–3.3s（一次性）。NFR2 ≤1.5s ✅（含 27.6s 压力样音）。

## 4. (c) 取消 / 失败提示 / 热词

- **取消**：① 按住后滑出 PTT 键（12dp slop）→ 键变红「松开取消」，松开取消不上屏（`PTT_CANCEL_REASON slide-out`）；② 返回键取消（`key=back`）；③ 系统夺走手势（ACTION_CANCEL）按取消语义。实测三路日志均为 `PTT_CANCEL dropped=true (audio discarded, never written to disk)` 且无 COMMIT。
- **失败兜底**（不瞎猜上屏）：低置信启发式与 mic README 同源——VAD 无语音段 / 空转写 / 无汉字 / 汉字密度 <0.25 字每秒 → 状态条红字「未识别到内容 · 请重说（reason）」，不上屏。实测：模拟器静音长按 1.5s → `PTT_FAIL source=ptt-release reason=no_speech_detected`，无 COMMIT。
- **hotwords.txt 热词后处理**（两级，W2 apply_hotwords 同源）：显式别名替换（长优先）+ 同音窗口匹配（无声调拼音）。默认表 = voice/poc/hotwords.txt，首用播种到 `filesDir/voice/hotwords.txt` 人工可编辑（L3 自动更新联通留 W 后续，见 §7）。实测 A/B：

```
热词开：text=我在星巴克点了一杯拿铁和一个可颂面包。  edits=同音替换: 可送→可颂
热词关：text=我在星巴克点了一杯拿铁和一个可送面包。
```

- 与 W2 的两处实现差异（如实记录）：① CT-Transformer 标点恢复模型未接（SenseVoice `use_itn` 自带标点，W2 已观察双标点问题，样音标点全部正确）；② 同音纠偏为**逐字拼音表**（assets/voice/pinyin.txt，pypinyin 默认读音生成），多音字取默认读音、无词级语境消歧（W2 用 lazy_pinyin 词级；纠偏只在「同音且正词不在场」时触发，风险有限）。

## 5. 验收实测（assembleDebug + adb 脚本）

### 5.1 构建

```
$ cd android && ./gradlew assembleDebug
> Task :app:compileDebugKotlin
> Task :app:packageDebug
> Task :app:assembleDebug
BUILD SUCCESSFUL
```

- APK：`android/app/build/outputs/apk/debug/app-debug.apk`（131,273,079 B；体积为 sherpa 4 ABI 原生库，**模型不在 APK**）。`aapt dump badging`：`versionCode=3 versionName=0.3.0-w14`、`sdkVersion:'29'`、`targetSdkVersion:'37'`、`uses-permission: RECORD_AUDIO`。

### 5.2 adb 端到端（`python3 android/w14-e2e.py`，最终一跑全文）

```
=== 0. 环境：安装 APK + 授权 + 启动（解除 stopped） ===
  [PASS] adb install  Success

=== 1. 模型首用下载（SHA256 钉死；模型不进 APK） ===
  [PASS] 单文件下载 + SHA256 校验（VAD）  single name=silero_vad.onnx dest=silero_vad.onnx sha256=9e2449e1...
  [PASS] 全量模型安装（SenseVoice int8 归档）  MODEL_OK already-installed installed=true model.int8.onnx=239233841,tokens.txt=315894,silero_vad.onnx=643854
  [PASS] w14_status 模型已就绪  [installed=true ...] engine_loaded=true mic_permission=true
  [PASS] sherpa-onnx 引擎加载（SenseVoice+VAD）  ENGINE_LOADED load_ms=508

=== 2. DebugReceiver 推 WAV → 转写结果确定性断言 ===
  [PASS] s1 转写逐字断言  ASR_EXPECT match=true expect=今天天气不错，我们下午去公园散步吧。 got=今天天气不错，我们下午去公园散步吧。
  [PASS] s1 转写文本正确
  [PASS] s1 全管线延迟 NFR2 ≤1500ms  elapsed_ms=158
  [PASS] s3 热词纠偏生效（可颂）  text=我在星巴克点了一杯拿铁和一个可颂面包。
  [PASS] s3 热词编辑记录（同音替换）
  [PASS] s3 热词对照组（关：可送）  text=我在星巴克点了一杯拿铁和一个可送面包。

=== 3. 分段转写 → 候选区滚动 → 松开上屏（W5 commit 通道） ===
  [PASS] 多段样音分段转写（≥2 段）  segments_logged=4
  [PASS] 候选区滚动多级刷新（≥2 次）  rolling_updates=4
  [PASS] 滚动文本 == 上屏文本  rolling_len=104
  [PASS] 松开上屏（COMMIT_OK）  COMMIT_OK source=debug-hook via=no-ic text=今天天气不错，…月面照片。
  [PASS] 上屏记录（COMMIT_RECORD）
  [PASS] 多段会话转写全文正确  rolling_ms=571 final_ms=1 text=今天天气不错，…昨天看新闻说，嫦娥探测器又传回了新的月面照片。
  [PASS] 松开→上屏延迟 NFR2 ≤1500ms（final_ms，流式终稿）  final_ms=1

=== 4. 真输入框上屏记录（通讯录新建联系人） ===
  [PASS] 找到可输入框（EditText）
  [PASS] IME 已绑定输入框
  [PASS] 经输入法 commit 通道上屏（via=input-connection）  COMMIT_OK source=debug-hook via=input-connection text=今天天气不错，我们下午去公园散步吧。
  [PASS] 上屏记录：输入框含转写文本

=== 5. 真实 PTT 长按（模拟器静音）→ 失败提示重说 ===
  [PASS] 解析到键盘窗口顶边（dumpsys window）  ime_top=1550
  [PASS] 长按 PTT 录音（AudioRecord 真实路径）  REC_STOP bytes=46080
  [PASS] 静音失败兜底（提示重说、不上屏）  PTT_FAIL source=ptt-release reason=no_speech_detected
  [PASS] 失败时无 COMMIT

=== 6. 取消手势（滑出 PTT / 返回键） ===
  [PASS] 滑出取消（PTT_CANCEL + slide-out）  PTT_CANCEL_REASON slide-out
  [PASS] 取消不上屏（无 COMMIT）
  [PASS] 返回键取消（PTT_CANCEL + key=back）  PTT_CANCEL_REASON key=back
  [PASS] 取消不上屏（无 COMMIT）

=== 7. AudioRecord 16k mono 内存缓冲探针 ===
  [PASS] 录音探针（不落盘、内存缓冲）  REC_OK sr=16000 mono pcm16 bytes=64000 frames=32000 rms=0.00015 memory-only
  [PASS] 采样字节数符合 16k mono pcm16（2s≈64000）  bytes=64000

=== 结果 ===
PASS=32 FAIL=0
```

logcat 断言依据（tag=W14，节选）：

```
ASR_EXPECT match=true expect=今天天气不错，我们下午去公园散步吧。 got=今天天气不错，我们下午去公园散步吧。
ASR_RESULT source=debug-hook wav=/data/local/tmp/w14/s3.wav text=我在星巴克点了一杯拿铁和一个可颂面包。 ... edits=同音替换: 可送→可颂
SEGMENT i=1 text=今天天气不错，我们下午去公园散步吧。 source=debug-hook
SEGMENT i=4 text=昨天看新闻说，嫦娥探测器又传回了新的月面照片。 source=debug-hook
PTT_ROLLING text=今天天气不错，…（逐段增长）…
COMMIT_OK source=debug-hook via=input-connection text=今天天气不错，我们下午去公园散步吧。
COMMIT_RECORD source=debug-hook text=今天天气不错，我们下午去公园散步吧。
REC_START sr=16000 mono pcm16 memory-buffer / REC_STOP bytes=46080
PTT_FAIL source=ptt-release reason=no_speech_detected
PTT_CANCEL_REASON slide-out / key=back → PTT_CANCEL dropped=true (audio discarded, never written to disk)
REC_OK sr=16000 mono pcm16 bytes=64000 frames=32000 rms=0.00015 memory-only
```

### 5.3 测试钩子（(d)，仅 debug 包，release 忽略）

```
adb shell am broadcast -n com.mineinput.ime/.DebugReceiver -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_status
adb shell am broadcast -n ... --es cmd w14_model [--es url <u> --es sha256 <s> --es name <n> --es dest <rel>]
adb shell am broadcast -n ... --es cmd w14_asr --es wav /data/local/tmp/w14/s1.wav [--es expect <text>] [--es no_hotwords 1] [--es hotwords <path>]
adb shell am broadcast -n ... --es cmd w14_ptt --es wav /data/local/tmp/w14/s1.wav [--es expect <text>]
adb shell am broadcast -n ... --es cmd w14_rec --es ms 2000
```

`w14_ptt` 与真实 PTT 松开走**同一条** `VoiceInput.finishSession` 路径（喂段→收尾段→热词→低置信→commit），断言确定性来自 W2 的 say 样音（逐字期望文本直接写进 `expect`）。

## 6. 期间踩坑记录（已解决）

1. **隐式广播被 API 34 丢弃**：`am broadcast -a com.mineinput.ime.DEBUG_ACTION` 不带组件时 `result=0` 且 receiver 不投递（stopped-state/后台广播限制；且 install 后未启动过的 app 是 stopped 状态）→ 验收脚本必须 `-n com.mineinput.ime/.DebugReceiver` 显式组件 + 先 `am start` 一次。
2. **Android toybox 无 bunzip2**（只有 tar），`tar -xjf` 在设备上不可用 → 归档解压用 commons-compress 纯 Java（BZip2CompressorInputStream + TarArchiveInputStream），已用宿主 JVM 对同一 jar 先行验证解出的文件 SHA256 与 W2 目录一致。
3. **AGP 9 不支持 `implementation(files("x.aar"))`**（Direct local .aar file dependencies are not supported）→ 本地 Maven 仓库布局引入。
4. **松开时重跑整段 ASR 会让 NFR2 与音频时长线性相关**（27.6s 样音实测 1797ms > 1500ms）→ 重构为「流式终稿」：段在说话中即带 pre-roll 转写为终稿，松开只补收尾段，final_ms 降为毫秒级，且滚动文本恒等于上屏文本。
5. **e2e 旧日志假阳性**（与 W11 e2e 教训同）：`wait_for` 命中上一步残留行（s3 断言错拿 s1 行）→ 所有触发统一「logcat -c → 广播 → 等新鲜行」。
6. **模拟器静音是特性不是 bug**：emu 麦克风输出静音（rms≈0.00015），恰好让失败兜底断言确定性成立；真机噪声环境准确率待 T1 机型验证（W2 同口径）。

## 7. 遗留项

1. **CT-Transformer 标点恢复未接**（FR2 管线四段中的「标点恢复」以 SenseVoice use_itn 内置标点替代）：int8 标点模型（61.7MB）已在 W2 清单，接入点 `AsrEngine.transcribe` 一处；样音标点已全对，真人口语标点质量需 T1 评估。
2. **热词与 L3 自动更新的联通**：当前 hotwords.txt 为本地文件（人工可编辑）；W11 同步通道已有热词集合并语义（`SyncManager.store.hotwords()`），把同步热词并入 `Hotwords.apply` 的词条源是小改动，待同意门控产品化后接。
3. **同音纠偏为逐字拼音表**：多音字取默认读音（如「重庆」类窗口会误配）；升级路径是词级拼音词典或 sherpa-onnx 内置 HomophoneReplacer（2.0.1 已有 `HomophoneReplacerConfig`，需配套数据文件）。
4. **APK 体积 131MB**（sherpa 4 ABI 原生库）：产物分发时应 ABI split 或只保留 arm64-v8a（当前 debug 全 ABI 便于模拟器/真机通用）；模型 239MB 为常驻磁盘（NFR5 百 MB 级达标），内存 RSS 未量化（沿 W2 遗留）。
5. **滚动粒度 = VAD 段**（与 W2 同口径）：SenseVoice 整句级识别，段内不逐字滚动；更细粒度需流式模型（zipformer streaming）。
6. **真机未测**：emulator-5554（arm64）为唯一实测设备；真人语音/嘈杂环境准确率、AudioRecord 各机型兼容待 T1。
7. **release 包未出**（D12 侧载收口时出）；DebugReceiver 在 release 直接忽略（既有语义保持）。
