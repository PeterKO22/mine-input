/*
 * mine-input W16 — MixedInputEngine 的 librime 实现（接线草案 1a：TrimeRimeBridge 复刻 + 数据部署）。
 *
 * 数据流：assets/rime/{shared,user}（ping_wubi_mixed schema + wubi86/pinyin_simp 词库）
 *   → filesDir/rime_{shared,user} → startupRime(shared, user, ver, fullCheck) 设备端部署
 *   → selectRimeSchema("ping_wubi_mixed") → onLetter=processRimeKey → getRimeCandidates
 *   → commit=selectRimeCandidate+getRimeCommit（L1 词频/造词由 librime userdb 在 commit 时学习）。
 *
 * 线程模型（接线草案 §5）：librime 无内部锁 → 所有 native 调用投递到单线程 executor 串行执行。
 * ⚠ 公开方法都经 onEngineThread 包裹；引擎线程内部只能调 *Inner（再进 onEngineThread 会自锁）。
 */
package com.mineinput.ime.engine

import com.osfans.trime.core.Rime
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class RimeMixedEngine : MixedInputEngine {

    companion object {
        const val TAG = "W16"
        const val SCHEMA = "ping_wubi_mixed"
        const val VERSION = "0.4.0-w16"
        /** X11 keysym：librime process_key 直接收 keysym（字母=ASCII 码）。 */
        const val XK_BACKSPACE = 0xFF08
        const val XK_RETURN = 0xFF0D
        const val XK_ESCAPE = 0xFF1B
        const val XK_SPACE = 0x0020
    }

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "w16-rime-engine").apply { isDaemon = true }
    }

    @Volatile
    var isStarted = false
        private set

    /** deploy 通知（type=3）与全部 JNI 通知记录，供报告/断言用。 */
    val deployMessages = mutableListOf<String>()
    val deployCount = AtomicLong(0)

    private fun <T> onEngineThread(block: () -> T): T =
        executor.submit(block).get(60, TimeUnit.SECONDS)

    override fun startup(sharedDir: File, userDir: File, fullCheck: Boolean): Boolean = onEngineThread {
        // JNI 通知回流（type: 0=unknown 1=schema 2=option 3=deploy）：只记录，永不抛
        Rime.messageListener = { type, params ->
            val value = params.joinToString(",") { it.toString() }
            synchronized(deployMessages) {
                if (deployMessages.size < 64) deployMessages.add("$type:$value")
            }
            if (type == 3) deployCount.incrementAndGet()
        }
        Rime.startupRime(sharedDir.absolutePath, userDir.absolutePath, VERSION, fullCheck)
        // 部署异步（W15 实测）：轮询到 schema 可选中为止 = 部署完成
        val deadline = System.currentTimeMillis() + 30_000
        var selected = false
        while (!selected && System.currentTimeMillis() < deadline) {
            selected = Rime.selectRimeSchema(SCHEMA)
            if (!selected) Thread.sleep(200)
        }
        isStarted = selected
        selected
    }

    override fun selectSchema(schemaId: String): Boolean = onEngineThread {
        Rime.selectRimeSchema(schemaId)
    }

    override fun onLetter(ch: Char): List<EngineCandidate> = onEngineThread {
        Rime.processRimeKey(ch.lowercaseChar().code, 0)
        candidatesInner(0, 8)
    }

    override fun onKey(keycode: Int, mask: Int): Boolean = onEngineThread {
        Rime.processRimeKey(keycode, mask)
    }

    override fun candidates(startIndex: Int, limit: Int): List<EngineCandidate> =
        onEngineThread { candidatesInner(startIndex, limit) }

    private fun candidatesInner(startIndex: Int, limit: Int): List<EngineCandidate> =
        Rime.getRimeCandidates(startIndex, limit).map {
            EngineCandidate(it.text, it.comment)
        }

    override fun commit(index: Int): String = onEngineThread {
        Rime.selectRimeCandidate(index, false)
        var text = Rime.getRimeCommit().text ?: ""
        if (text.isEmpty()) {
            // 未直接上屏（多段/长句）：提交剩余 composition 再取 commit
            Rime.commitRimeComposition()
            text = Rime.getRimeCommit().text ?: ""
        }
        text
    }

    override fun drainCommit(): String = onEngineThread {
        Rime.getRimeCommit().text ?: ""
    }

    override fun rawInput(): String = onEngineThread {
        Rime.getRimeRawInput()
    }

    override fun status(): EngineStatus = onEngineThread {
        val s = Rime.getRimeStatus()
        EngineStatus(s.schemaId, s.isComposing, s.isAsciiMode)
    }

    override fun clear() {
        onEngineThread {
            Rime.clearRimeComposition()
            Rime.getRimeCommit() // 丢弃任何 pending commit
        }
    }

    override fun shutdown() {
        onEngineThread {
            Rime.exitRime()
            isStarted = false
        }
    }
}
