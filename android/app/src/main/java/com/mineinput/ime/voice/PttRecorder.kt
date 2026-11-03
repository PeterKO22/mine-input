package com.mineinput.ime.voice

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlin.concurrent.thread

/**
 * W14 PTT 录音（(b)）：AudioRecord 16k mono PCM16 → **内存缓冲（不落盘）**。
 * 按住期间：0.5s 块流式喂 VAD → 完成段带 pre-roll 即转写（滚动文本 == 最终上屏文本）；
 * 松开：收尾段 + 热词组装 → VoiceInput.finishSession（低置信→提示重说；正常→commit 通道上屏）；
 * 取消：缓冲即弃（音频无处落盘）。
 */
class PttRecorder(
    private val ctx: Context,
    private val onRolling: (String) -> Unit,
    private val onEvent: (String) -> Unit = {},
) {
    companion object {
        const val TAG = "W14"
    }

    interface Callback {
        fun onCommitted(text: String, finalMs: Long, numSegments: Int)
        fun onFailed(reason: String)
    }

    @Volatile
    private var recording = false
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var session: VoiceInput.PttSession? = null
    private var bytesCaptured = 0

    val isRecording: Boolean get() = recording

    /** 开始录音。false=设备/权限问题（调用方给失败提示）。 */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (recording) return true
        val minBuf = AudioRecord.getMinBufferSize(
            AsrEngine.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufSize = maxOf(minBuf, AsrEngine.SAMPLE_RATE * 2 * 2)
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                AsrEngine.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize,
            )
        } catch (e: Throwable) {
            Log.i(TAG, "REC_FAIL create ${e.javaClass.simpleName}: ${e.message}")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.i(TAG, "REC_FAIL not-initialized state=${rec.state}")
            rec.release()
            return false
        }
        session = try {
            VoiceInput.PttSession(ctx = ctx, source = "ptt-live")
        } catch (e: Throwable) {
            Log.i(TAG, "REC_FAIL session ${e.message}")
            rec.release()
            return false
        }
        audioRecord = rec
        bytesCaptured = 0
        recording = true
        rec.startRecording()
        Log.i(TAG, "REC_START sr=${AsrEngine.SAMPLE_RATE} mono pcm16 memory-buffer")
        captureThread = thread(name = "w14-ptt-capture") {
            val buf = ShortArray(AsrEngine.SAMPLE_RATE / 2) // 0.5s 块
            while (recording) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) break
                bytesCaptured += n * 2
                val f = FloatArray(n)
                for (i in 0 until n) f[i] = buf[i] / 32768f
                val rolling = session?.feed(f)
                if (rolling != null) onRolling(rolling) // 候选区实时滚动（与上屏文本一致）
            }
            Log.i(TAG, "REC_STOP bytes=$bytesCaptured")
        }
        return true
    }

    /**
     * 松开上屏：停采 → 收尾段 + 组装 + commit（后台线程，finalMs 与音频时长解耦）。
     * 低置信走 onFailed（提示重说、不瞎猜上屏）。
     */
    fun commit(ctx: Context, callback: Callback) {
        if (!recording && session == null) {
            callback.onFailed("no-audio")
            return
        }
        recording = false
        val rec = audioRecord
        audioRecord = null
        try {
            rec?.stop()
        } catch (_: Throwable) {
        }
        rec?.release()
        captureThread?.join(2000)
        captureThread = null

        val s = session
        session = null
        if (s == null) {
            callback.onFailed("no-session")
            return
        }
        val appCtx = ctx.applicationContext
        thread(name = "w14-ptt-commit") {
            try {
                val t0 = System.currentTimeMillis()
                val r = VoiceInput.finishSession(appCtx, s, "ptt-release", rollingMs = 0)
                Log.i(TAG, "PTT_DONE committed=${r.committed} reason=${r.reason} " +
                    "release_total_ms=${System.currentTimeMillis() - t0} final_ms=${r.finalMs} " +
                    "segments=${r.numSegments} text=${r.text}")
                if (r.committed) {
                    callback.onCommitted(r.text, r.finalMs, r.numSegments)
                } else {
                    callback.onFailed(r.reason)
                }
            } catch (e: Throwable) {
                Log.i(TAG, "PTT_FAIL exception ${e.javaClass.simpleName}: ${e.message}")
                callback.onFailed("exception:${e.message}")
            }
        }
    }

    /** 取消（滑出/返回）：缓冲即弃，不上屏。 */
    fun cancel() {
        recording = false
        val rec = audioRecord
        audioRecord = null
        try {
            rec?.stop()
        } catch (_: Throwable) {
        }
        rec?.release()
        captureThread?.join(1000)
        captureThread = null
        session?.abandon()
        session = null
    }
}
