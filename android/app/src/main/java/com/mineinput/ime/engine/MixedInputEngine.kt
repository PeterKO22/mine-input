/*
 * mine-input W16 — 混输引擎契约（engine/docs/android-wiring-draft.md §2）。
 *
 * 与上游解耦的最小接口：W5 骨架落点（MineImeService.candidates()/onLetter）只依赖本文件。
 * 线程约定：除 startup/shutdown 外的调用可来自任意线程，实现体内部自行串行化
 * （librime 无内部锁，接线草案 §5：单线程 executor 亲和）。
 * 说明：草案里 startup/selectSchema 为 suspend 签名——本工程零第三方依赖（无 kotlinx-coroutines），
 * 改为阻塞语义（调用方放 IO 线程），其余签名与草案一致。
 */
package com.mineinput.ime.engine

import java.io.File

/** 候选：text=上屏文本，comment=注释（z 反查五笔码等）。 */
data class EngineCandidate(val text: String, val comment: String = "")

data class EngineStatus(val schemaId: String, val isComposing: Boolean, val isAsciiMode: Boolean)

interface MixedInputEngine {
    /**
     * 启动引擎并完成数据部署（首次 fullCheck=设备端编译码表，W15 实测 2.3–4.5s）。
     * 阻塞至 schema 可选中；必须在 IO/后台线程调用。
     */
    fun startup(sharedDir: File, userDir: File, fullCheck: Boolean): Boolean

    fun selectSchema(schemaId: String): Boolean

    /** 字母键 → 更新 composing，返回本帧候选（形码优先/拼音前移由 schema 保证）。 */
    fun onLetter(ch: Char): List<EngineCandidate>

    /** 特殊键（Backspace/Return/Escape…）：返回 true=已消费。 */
    fun onKey(keycode: Int, mask: Int = 0): Boolean

    fun candidates(startIndex: Int = 0, limit: Int = 8): List<EngineCandidate>

    /** 点选第 idx 个候选 → 返回上屏文本（selectRimeCandidate + getRimeCommit，W5 commit 通道）。 */
    fun commit(index: Int): String

    /** 取走引擎自动上屏文本（无则空串）；每个键后由 IMS 调用。 */
    fun drainCommit(): String

    fun rawInput(): String

    fun status(): EngineStatus

    /** Escape 语义：清空 composing。 */
    fun clear()

    fun shutdown()
}
