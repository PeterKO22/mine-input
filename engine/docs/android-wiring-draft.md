# W15 接线草案：把混输引擎接进 android/ IMS 骨架（仅草案，不实施）

> 依据：W15 路径 A 实测（Trime v3.3.13 `librime_jni.so` 被外部 APK 复用成功，
> 候选输出 w→人 / gggg→王 / pinyin→拼音 / nihao→你好 / zni 反查 全部与 W1 一致）。
> 落点：W5 骨架 `MineImeService.candidates()` / `onLetter`（FR1 混输）；PTT（FR2）不动。
> 本文件只给接口签名与步骤，代码不写入 android/（目录所有权约束）。

## 1. 交付形态选择（二选一，建议 1a）

| 方案 | 做法 | 依赖面 | GPLv3 影响 |
|---|---|---|---|
| **1a. 胶水类复刻（建议）** | 复刻 Trime 的 JNI 胶水层（`com.osfans.trime.core.Rime` 等 6 个数据类 + 静态 native 声明，约 200 行 Kotlin），类名保持一致以绑定 `Java_com_osfans_trime_core_Rime_*` 符号 | 只需 `librime_jni.so`（单 .so 静态合并 librime+deps） | 复刻 Trime 源码 → GPLv3（同权开源） |
| 1b. dex 直用 | 直接打包 Trime classes.dex 的 core/* 部分（W15 POC 即此法，最省事但 dex 受上游版本约束） | Trime dex + .so | GPLv3（整包） |
| 1c. 自写 JNI shim | 用 NDK 自写 shim 调 `rime_get_api`（.so 已导出该符号）+ BSD-3 的 librime 语义 | 需 NDK 构建链（路径 B 落地后可切） | shim 自定许可；若 .so 换成自编 librime（BSD-3）则 android/ 可闭源 |

> W5 §1.4 已预告：一旦接入 Trime/librime 内核，android/ 端衍生部分须转 GPLv3；
> 个人分发可接受。1c + 路径 B 自编 librime 是唯一能保留许可选择权的路线。

## 2. 接口签名（建议新增 `android/app/src/main/java/com/mineinput/ime/engine/`）

```kotlin
// ---- engine-api.kt：W5 骨架落点依赖的最小契约（与 SPI/上游解耦）----
data class EngineCandidate(val text: String, val comment: String = "")   // comment=反查五笔码等
data class EngineStatus(val schemaId: String, val isComposing: Boolean, val isAsciiMode: Boolean)

interface MixedInputEngine {
    /** 启动引擎并完成数据部署（首次 fullCheck，设备端编译码表；W15 实测 2.3–4.5s）。须在 IO 线程。 */
    suspend fun startup(sharedDir: File, userDir: File): Boolean
    suspend fun selectSchema(schemaId: String): Boolean          // "ping_wubi_mixed"
    /** 字母键 → 更新 composing，返回本帧候选（形码优先/拼音前移由 schema 保证） */
    fun onLetter(ch: Char): List<EngineCandidate>
    /** 特殊键（Backspace/Enter/Space/Escape…）：返回 true=已消费 */
    fun onKey(keycode: Int, mask: Int = 0): Boolean
    fun candidates(startIndex: Int = 0, limit: Int = 8): List<EngineCandidate>
    /** 点选第 idx 个候选 → 返回上屏文本（selectRimeCandidate + getRimeCommit） */
    fun commit(index: Int): String
    fun rawInput(): String
    fun status(): EngineStatus
    fun clear()                                                   // Escape 语义
    fun shutdown()                                                // exitRime
}

// ---- trime-bridge.kt：1a 方案的实现体（签名对齐 JNI 符号面）----
object TrimeRimeBridge {
    @JvmStatic external fun startupRime(sharedDir: String, userDir: String, versionName: String, fullCheck: Boolean)
    @JvmStatic external fun exitRime()
    @JvmStatic external fun processRimeKey(keycode: Int, mask: Int): Boolean
    @JvmStatic external fun simulateRimeKeySequence(keySequence: String): Boolean
    @JvmStatic external fun getRimeCandidates(startIndex: Int, limit: Int): Array<CandidateProto>
    @JvmStatic external fun selectRimeCandidate(index: Int, global: Boolean): Boolean
    @JvmStatic external fun getRimeCommit(): CommitProto
    @JvmStatic external fun getRimeContext(): ContextProto
    @JvmStatic external fun getRimeStatus(): StatusProto
    @JvmStatic external fun clearRimeComposition()
    @JvmStatic external fun commitRimeComposition(): Boolean
    @JvmStatic external fun selectRimeSchema(schemaId: String): Boolean
    @JvmStatic external fun getCurrentRimeSchema(): String
    init { System.loadLibrary("rime_jni") }
}
// 附：CommitProto(text: String?) / CandidateProto(text, comment, label) /
//     CompositionProto / ContextProto / StatusProto —— 与 .so 的 FindClass 名严格一致
//     （com/osfans/trime/core/*），字段构造签名须与 v3.3.13 一致，勿改名。
```

## 3. 步骤（实施顺序）

1. **产物入仓**：`engine/poc/pathA/apk_extracted/lib/arm64-v8a/librime_jni.so` →
   `android/app/src/main/jniLibs/arm64-v8a/librime_jni.so`（5.9MB，含 librime+opencc+leveldb+marisa 全部静态合并）。
2. **胶水层**：按 §2 复刻 6 个数据类 + `TrimeRimeBridge`（或 1b：引入 dex）。类名不可改（JNI 符号绑定）。
3. **数据部署**：`MineImeService.onCreate`（IO 线程）把 `assets/rime/{shared,user}`（W15 脚本同一套
   schema+词库）拷到 `filesDir/rime_{shared,user}` → `startup(...)`；
   首次 fullCheck=true（设备端编译 wubi86/pinyin_simp 码表，W15 实测秒级），此后 false。
4. **落点接线**：
   - `MineImeService.onLetter(c)` → `engine.onLetter(c)` → `KeyboardView.updateState` 候选栏
   - 候选点选 → `engine.commit(i)` → `currentInputConnection.commitText`
   - Backspace/Enter/Space → `engine.onKey(...)`
   - PTT（`onPttDown/Up`）不动，仍走 W2 占位。
5. **线程模型**：librime 无内部锁，必须单线程亲和（Trime 用 RimeDispatcher 串行）——
   `MixedInputEngine` 实现体内部持单线程 `Executor`，所有 native 调用投递到该线程。
6. **生命周期**：`onCreate→startup`、`onDestroy→shutdown`；`ascii_mode` 等 option 经
   `setRimeOption` 透传（W5 骨架的中/西文切换）。
7. **许可合规**：引入 `.so`+胶水类后，android/ 端衍生部分按 GPLv3 发布（LICENSE 文件 + 开源仓），
   个人分发可接受；若要闭源，走 1c + 路径 B 自编 librime（BSD-3）。
8. **回归**：复用 W15 `run-poc-demo.sh` 的断言（w/gggg/pinyin/nihao/zni）作为引擎回归用例，
   W5 `w11-e2e.py` 作为 IMS 端到端回归。
