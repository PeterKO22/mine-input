package com.mineinput.ime.voice

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.File
import kotlin.concurrent.thread

/**
 * W14 端到端调试钩子（(d)；仅 debug 包，DebugReceiver 转发）：
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_status
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_model \
 *       [--es url <url> --es sha256 <sha> --es name <n> --es dest <rel>]
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_asr \
 *       --es wav /data/local/tmp/w14/s1.wav [--es expect <text>] [--es no_hotwords 1] [--es hotwords <path>]
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_ptt \
 *       --es wav /data/local/tmp/w14/s1.wav [--es expect <text>]
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd w14_rec --es ms 3000
 * 结果全部打 logcat（tag=W14），供 android/w14-e2e.sh/.py 确定性断言。
 * w14_ptt 与真实 PTT 松开走同一 VoiceInput.runPttSession → commit 通道。
 */
object W14Debug {

    const val TAG = "W14"

    fun handle(ctx: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd") ?: ""
        thread(name = "w14-debug") {
            try {
                when (cmd) {
                    "w14_status" -> {
                        val mic = ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED
                        Log.i(
                            TAG,
                            "STATUS model[${ModelManager.status(ctx)}] engine_loaded=${AsrEngine.isLoaded} " +
                                "mic_permission=$mic ime_active=${com.mineinput.ime.MineImeService.active != null}"
                        )
                    }
                    "w14_model" -> {
                        val url = intent.getStringExtra("url")
                        if (url != null) {
                            val art = ModelManager.Artifact(
                                name = intent.getStringExtra("name") ?: "custom.bin",
                                url = url,
                                sha256 = intent.getStringExtra("sha256") ?: "",
                                sizeBytes = 0L,
                            )
                            val dest = intent.getStringExtra("dest") ?: "custom/${art.name}"
                            ModelManager.installOne(ctx, art, dest) { Log.i(TAG, it) }
                        } else {
                            val ok = ModelManager.install(ctx) { Log.i(TAG, it) }
                            if (ok && AsrEngine.load(ctx)) {
                                Log.i(TAG, "ENGINE_READY after-install")
                            }
                        }
                    }
                    "w14_asr" -> {
                        if (!AsrEngine.load(ctx)) {
                            Log.i(TAG, "ASR_FAIL reason=engine-not-loaded (run w14_model first)")
                            return@thread
                        }
                        val wav = intent.getStringExtra("wav") ?: ""
                        val samples = Wav.readPcm16(wav)
                        val useHw = intent.getStringExtra("no_hotwords") != "1"
                        val hwPath = intent.getStringExtra("hotwords")
                        val r = AsrEngine.transcribe(ctx, samples, useHotwords = useHw, hotwordsPath = hwPath)
                        Log.i(
                            TAG,
                            "ASR_RESULT source=debug-hook wav=$wav text=${r.text} low_conf=${r.lowConfidence} " +
                                "reason=${r.reason} conf=${r.confidence} segments=${r.numSegments} " +
                                "speech_s=${r.speechSeconds} vad_ms=${r.vadMs} asr_ms=${r.asrMs} " +
                                "hotword_ms=${r.hotwordMs} elapsed_ms=${r.elapsedMs}" +
                                if (r.edits.isEmpty()) "" else " edits=${r.edits.joinToString(";")}"
                        )
                        val expect = intent.getStringExtra("expect")
                        if (expect != null) {
                            Log.i(TAG, "ASR_EXPECT match=${r.text == expect} expect=$expect got=${r.text}")
                        }
                    }
                    "w14_ptt" -> {
                        if (!AsrEngine.load(ctx)) {
                            Log.i(TAG, "PTT_FAIL reason=engine-not-loaded (run w14_model first)")
                            return@thread
                        }
                        val wav = intent.getStringExtra("wav") ?: ""
                        val samples = Wav.readPcm16(wav)
                        val expect = intent.getStringExtra("expect")
                        val result = VoiceInput.runPttSession(
                            ctx, samples, source = "debug-hook",
                            onRolling = { text -> Log.i(TAG, "PTT_ROLLING text=$text") },
                        )
                        Log.i(
                            TAG,
                            "PTT_DONE committed=${result.committed} reason=${result.reason} " +
                                "rolling_ms=${result.rollingMs} final_ms=${result.finalMs} " +
                                "text=${result.text}"
                        )
                        if (expect != null) {
                            Log.i(TAG, "PTT_EXPECT match=${result.text == expect && result.committed} " +
                                "expect=$expect got=${result.text} committed=${result.committed}")
                        }
                    }
                    "w14_rec" -> {
                        val ms = intent.getStringExtra("ms")?.toIntOrNull()
                            ?: intent.getIntExtra("ms", 3000)
                        recordProbe(ctx, ms)
                    }
                    else -> Log.i(TAG, "UNKNOWN_CMD $cmd")
                }
            } catch (e: Throwable) {
                Log.i(TAG, "CMD_ERROR cmd=$cmd ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /** AudioRecord 实采探针：16k mono PCM16 → 内存（不落盘），报字节数/电平。 */
    private fun recordProbe(ctx: Context, ms: Int) {
        if (ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "REC_FAIL reason=no-permission")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            AsrEngine.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            AsrEngine.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, AsrEngine.SAMPLE_RATE * 2),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.i(TAG, "REC_FAIL reason=not-initialized state=${rec.state}")
            rec.release()
            return
        }
        rec.startRecording()
        val wantBytes = AsrEngine.SAMPLE_RATE * 2 * ms / 1000
        var got = 0
        var sumSq = 0.0
        val buf = ShortArray(4096)
        while (got < wantBytes) {
            val n = rec.read(buf, 0, minOf(buf.size, (wantBytes - got) / 2))
            if (n <= 0) break
            for (i in 0 until n) sumSq += (buf[i] / 32768.0) * (buf[i] / 32768.0)
            got += n * 2
        }
        rec.stop()
        rec.release()
        val frames = got / 2
        val rms = if (frames > 0) kotlin.math.sqrt(sumSq / frames) else 0.0
        Log.i(TAG, "REC_OK sr=${AsrEngine.SAMPLE_RATE} mono pcm16 bytes=$got frames=$frames rms=%.5f memory-only".format(rms))
    }
}
