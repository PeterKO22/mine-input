package com.mineinput.ime.voice

import android.content.Context
import android.util.Log
import com.mineinput.ime.MineImeService
import com.mineinput.ime.Prefs
import com.mineinput.ime.sync.SyncManager
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

/**
 * W14 PTT 会话编排（(b)(c)）：内存 PCM → 分段转写（带 pre-roll）→ 候选区滚动 →
 * 松开上屏 / 取消 / 失败兜底。
 *
 * 关键设计：**滚动文本 == 上屏文本**。每段 VAD 完成即带 0.25s pre-roll 转写并纠偏
 * （与 AsrEngine.transcribe 的逐段切片同构），松开只做收尾段 + 热词组装，不重跑整段
 * ASR —— 「松开→上屏」延迟与音频时长解耦（NFR2）。
 *
 * 上屏走 W5 commit 通道（MineImeService.currentInputConnection.commitText），并按 W11
 * 语义记 voice_session 交互事件（同意/熔断门控在 SyncManager 内）。
 * 音频缓冲为会话内存，转写完/取消即弃（不落盘）。
 */
object VoiceInput {

    const val TAG = "W14"

    data class SessionResult(
        val text: String,
        val rawText: String,
        val lowConfidence: Boolean,
        val reason: String,
        val confidence: Float,
        val numSegments: Int,
        val speechSeconds: Float,
        val edits: List<String>,
        val committed: Boolean,
        val rollingMs: Long,
        val finalMs: Long, // 松开→上屏耗时（NFR2 口径：收尾段转写 + 热词 + commit）
    )

    /**
     * 一次按住说话会话。feed() 在录音线程流式喂入；release() 在松开时收尾并上屏；
     * abandon() 取消（缓冲即弃，不上屏）。测试钩子（(d) w14_ptt）与真实 PTT 共用。
     */
    class PttSession(
        private val ctx: Context,
        useHotwords: Boolean = true,
        hotwordsPath: String? = null,
        private val source: String = "ptt",
    ) {
        private val live = AsrEngine.LiveSession()
        private val entries: List<Hotwords.Entry>
        private val pinyin: Map<Char, String>
        private val useHotwords = useHotwords

        private val rawSegs = ArrayList<String>()
        private val corrSegs = ArrayList<String>()
        val edits = ArrayList<String>()

        init {
            val f = if (useHotwords) Hotwords.hotwordsFile(ctx, hotwordsPath) else null
            entries = if (f != null) Hotwords.parse(f.readText(Charsets.UTF_8)) else emptyList()
            pinyin = if (entries.isNotEmpty()) Hotwords.loadPinyin(ctx) else emptyMap()
        }

        /** 喂入一块 PCM；返回纠偏后的累计滚动文本（无新段返回 null）。 */
        fun feed(chunk: FloatArray): String? {
            val new = live.feed(chunk)
            if (new.isEmpty()) return null
            for (raw in new) addSegment(raw)
            return corrSegs.joinToString("")
        }

        private fun addSegment(raw: String) {
            rawSegs.add(raw)
            val corrected = if (entries.isNotEmpty()) {
                val (t, e) = Hotwords.apply(raw, entries, pinyin, useHomophone = true)
                edits.addAll(e)
                t
            } else raw
            corrSegs.add(corrected)
            Log.i(TAG, "SEGMENT i=${rawSegs.size} text=$corrected source=$source")
        }

        /** 松开：收尾段 + 热词组装 + 低置信判定；不上屏（调用方决定）。 */
        fun release(): RawOutcome {
            val t0 = System.currentTimeMillis()
            for (raw in live.finish()) addSegment(raw)
            val text = corrSegs.joinToString("")
            val rawText = rawSegs.joinToString("")
            val speechSeconds = live.speechSamples.toDouble() / AsrEngine.SAMPLE_RATE
            val han = text.count { it in '\u4e00'..'\u9fff' }
            val (low, reason) = when {
                corrSegs.isEmpty() -> true to "no_speech_detected"
                text.isEmpty() -> true to "empty_transcription"
                han == 0 -> true to "no_han_characters"
                speechSeconds > 0 && han / speechSeconds < 0.25 -> true to "low_char_density"
                else -> false to "ok"
            }
            val confidence =
                if (speechSeconds <= 0) 0f
                else (han / (4.5 * speechSeconds)).coerceIn(0.0, 1.0).toFloat()
            return RawOutcome(
                text = text, rawText = rawText, lowConfidence = low, reason = reason,
                confidence = confidence, numSegments = corrSegs.size,
                speechSeconds = speechSeconds.toFloat(), edits = edits.toList(),
                finalMs = System.currentTimeMillis() - t0,
            )
        }

        fun abandon() {
            live.abandon()
            rawSegs.clear()
            corrSegs.clear()
            Log.i(TAG, "PTT_CANCEL dropped=true (audio discarded, never written to disk)")
        }
    }

    data class RawOutcome(
        val text: String,
        val rawText: String,
        val lowConfidence: Boolean,
        val reason: String,
        val confidence: Float,
        val numSegments: Int,
        val speechSeconds: Float,
        val edits: List<String>,
        val finalMs: Long,
    )

    /**
     * 一次性完整会话（(d) 测试钩子 w14_ptt 与真实松开共用同一路径）：
     * 0.5s 块喂入（逐段日志 + onRolling 滚动回传）→ release → 低置信提示重说 /
     * commit 通道上屏 + 记录。
     */
    fun runPttSession(
        ctx: Context,
        samples: FloatArray,
        source: String,
        onRolling: ((String) -> Unit)? = null,
        useHotwords: Boolean = true,
        hotwordsPath: String? = null,
    ): SessionResult {
        val t0 = System.currentTimeMillis()
        val session = PttSession(ctx, useHotwords, hotwordsPath, source)
        val chunk = AsrEngine.SAMPLE_RATE / 2
        var i = 0
        while (i < samples.size) {
            val end = minOf(i + chunk, samples.size)
            val rolling = session.feed(samples.copyOfRange(i, end))
            if (rolling != null) onRolling?.invoke(rolling)
            i = end
        }
        return finishSession(ctx, session, source, System.currentTimeMillis() - t0)
    }

    /** 收尾一条会话：收尾段 + 热词组装 + 低置信判定 + 上屏/失败（真实 PTT 与钩子同用）。 */
    fun finishSession(ctx: Context, session: PttSession, source: String, rollingMs: Long): SessionResult {
        val out = session.release()
        Log.i(
            TAG,
            "ASR_RESULT source=$source text=${out.text} low_conf=${out.lowConfidence} reason=${out.reason} " +
                "conf=${out.confidence} segments=${out.numSegments} speech_s=${out.speechSeconds} " +
                "final_ms=${out.finalMs}" +
                if (out.edits.isEmpty()) "" else " edits=${out.edits.joinToString(";")}"
        )

        return if (out.lowConfidence) {
            Log.i(TAG, "PTT_FAIL source=$source reason=${out.reason}")
            SessionResult(
                out.text, out.rawText, out.lowConfidence, out.reason, out.confidence,
                out.numSegments, out.speechSeconds, out.edits,
                committed = false, rollingMs = rollingMs, finalMs = out.finalMs,
            )
        } else {
            val committed = commit(ctx, out.text, source)
            SessionResult(
                out.text, out.rawText, out.lowConfidence,
                if (committed) "ok" else "no-input-connection", out.confidence,
                out.numSegments, out.speechSeconds, out.edits,
                committed = committed, rollingMs = rollingMs, finalMs = out.finalMs,
            )
        }
    }

    /** 上屏 + 上屏记录（W5 commit 通道 + W11 voice_session 事件）。 */
    fun commit(ctx: Context, text: String, source: String): Boolean {
        val viaIc = MineImeService.active?.commitVoiceText(text) ?: false
        Log.i(TAG, "COMMIT_OK source=$source via=${if (viaIc) "input-connection" else "no-ic"} text=$text")
        // W11 语义：voice_session 交互事件（C0 同意 + 未熔断才入队上报）
        try {
            SyncManager.init(ctx)
            SyncManager.recordInteraction(
                JSONObject()
                    .put("ts", System.currentTimeMillis())
                    .put("device_id", Prefs.Pairing(ctx).deviceId)
                    .put("app_id", "com.mineinput.ime")
                    .put("kind", "voice_session")
                    .put("text_in", "")
                    .put("text_out", text)
            )
        } catch (e: Throwable) {
            Log.i(TAG, "COMMIT_RECORD_FAIL ${e.message}")
        }
        Log.i(TAG, "COMMIT_RECORD source=$source text=$text")
        return viaIc
    }
}

/** WAV(PCM16 mono) → 内存 FloatArray（(d) 测试钩子喂样音用；音频本体不写入应用目录）。 */
object Wav {
    fun readPcm16(path: String): FloatArray {
        RandomAccessFile(File(path), "r").use { raf ->
            if (raf.length() < 44) throw IllegalArgumentException("wav too short")
            val riff = ByteArray(4)
            raf.readFully(riff)
            if (String(riff) != "RIFF") throw IllegalArgumentException("not RIFF")
            raf.skipBytes(4)
            val wave = ByteArray(4)
            raf.readFully(wave)
            if (String(wave) != "WAVE") throw IllegalArgumentException("not WAVE")

            var sampleRate = 0
            var channels = 0
            var bits = 0
            var dataOffset = -1L
            var dataLen = 0
            while (raf.filePointer + 8 <= raf.length()) {
                val id = ByteArray(4)
                raf.readFully(id)
                val size = Integer.reverseBytes(raf.readInt())
                val name = String(id)
                if (name == "fmt ") {
                    val fmt = ByteArray(minOf(size, 16))
                    raf.readFully(fmt)
                    if (size > 16) raf.skipBytes(size - 16)
                    channels = (fmt[2].toInt() and 0xff) or ((fmt[3].toInt() and 0xff) shl 8)
                    sampleRate = (fmt[4].toInt() and 0xff) or ((fmt[5].toInt() and 0xff) shl 8) or
                        ((fmt[6].toInt() and 0xff) shl 16) or ((fmt[7].toInt() and 0xff) shl 24)
                    bits = (fmt[14].toInt() and 0xff) or ((fmt[15].toInt() and 0xff) shl 8)
                } else if (name == "data") {
                    dataOffset = raf.filePointer
                    dataLen = size
                    break
                } else {
                    raf.skipBytes(size + (size and 1))
                }
            }
            if (dataOffset < 0) throw IllegalArgumentException("no data chunk")
            if (channels != 1 || bits != 16) {
                throw IllegalArgumentException("want 16k mono pcm16, got sr=$sampleRate ch=$channels bits=$bits")
            }
            if (sampleRate != 16000) {
                throw IllegalArgumentException("want sampleRate=16000, got $sampleRate")
            }
            raf.seek(dataOffset)
            val bytes = ByteArray(dataLen)
            raf.readFully(bytes)
            val out = FloatArray(dataLen / 2)
            var i = 0
            while (i < out.size) {
                val lo = bytes[2 * i].toInt() and 0xff
                val hi = bytes[2 * i + 1].toInt()
                out[i] = ((hi shl 8) or lo).toShort() / 32768f
                i++
            }
            return out
        }
    }
}
