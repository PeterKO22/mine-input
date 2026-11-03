package com.mineinput.ime.voice

import android.content.Context
import android.util.Log
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.max
import kotlin.math.min

/**
 * W14 离线转写引擎（sherpa-onnx Android 预编译 AAR，SenseVoiceSmall int8 + Silero VAD）。
 * 管线语义与 voice/mic/pipeline.py 同源（W2）：
 *   PCM(16k mono f32, 内存) → Silero VAD 流式切段（0.5s 块喂入 + 0.25s 段边界 pre-roll）
 *   → SenseVoiceSmall(int8, use_itn 自带标点) → 标点串合并 → hotwords.txt 两级热词纠偏
 *   → 低置信启发式（不瞎猜，提示重说）。
 * 与 W2 的差异（如实记录）：CT-Transformer 标点恢复模型未接（SenseVoice use_itn 自带标点，
 * 双标点问题在 W2 已观察到）；同音纠偏为逐字拼音表（多音字取默认读音）。
 */
object AsrEngine {

    const val TAG = "W14"
    const val SAMPLE_RATE = 16000

    data class Result(
        val text: String,
        val rawText: String,
        val lowConfidence: Boolean,
        val reason: String,
        val confidence: Float,
        val numSegments: Int,
        val speechSeconds: Float,
        val vadMs: Long,
        val asrMs: Long,
        val hotwordMs: Long,
        val elapsedMs: Long,
        val segments: List<String>,
        val edits: List<String>,
    )

    private val lock = ReentrantLock()
    private var recognizer: OfflineRecognizer? = null
    private var vadConfig: VadModelConfig? = null

    val isLoaded: Boolean get() = lock.withLock { recognizer != null }

    /** 模型加载（一次常驻，之后转写零加载开销）。模型未安装返回 false。 */
    fun load(ctx: Context): Boolean = lock.withLock {
        if (recognizer != null) return true
        val root = ModelManager.modelRoot(ctx)
        val model = File(root, "sense-voice/model.int8.onnx")
        val tokens = File(root, "sense-voice/tokens.txt")
        val vadModel = File(root, "silero_vad.onnx")
        if (!model.exists() || !tokens.exists() || !vadModel.exists()) return false
        try {
            val t0 = System.currentTimeMillis()
            val mc = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = model.absolutePath,
                    language = "zh",
                    useInverseTextNormalization = true,
                ),
                tokens = tokens.absolutePath,
                numThreads = 2,
            )
            val cfg = OfflineRecognizerConfig(modelConfig = mc, decodingMethod = "greedy_search")
            recognizer = OfflineRecognizer(assetManager = null, config = cfg)
            vadConfig = VadModelConfig(
                sileroVadModelConfig = SileroVadModelConfig(
                    model = vadModel.absolutePath,
                    threshold = 0.5f,
                    minSilenceDuration = 0.5f,
                    minSpeechDuration = 0.3f,
                    windowSize = 512,
                    maxSpeechDuration = 20f,
                ),
                sampleRate = SAMPLE_RATE,
                numThreads = 1,
                provider = "cpu",
                debug = false,
            )
            Log.i(TAG, "ENGINE_LOADED load_ms=${System.currentTimeMillis() - t0} " +
                "model=${model.length()} tokens=${tokens.length()} vad=${vadModel.length()}")
            true
        } catch (e: Throwable) {
            Log.i(TAG, "ENGINE_LOAD_FAIL ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    private fun requireReady(): Pair<OfflineRecognizer, VadModelConfig> =
        lock.withLock {
            val r = recognizer ?: throw IllegalStateException("engine not loaded")
            val v = vadConfig ?: throw IllegalStateException("vad config missing")
            r to v
        }

    /** 单段 ASR（SenseVoice）。 */
    private fun asrSegment(rec: OfflineRecognizer, seg: FloatArray): String {
        val stream = rec.createStream()
        try {
            stream.acceptWaveform(seg, SAMPLE_RATE)
            rec.decode(stream)
            return rec.getResult(stream).text.trim()
        } finally {
            stream.release()
        }
    }

    /**
     * VAD 切段（W2 同源）：0.5s 块流式喂入（整段喂入会丢早前段——W2 踩坑 1），
     * 段边界前后各扩 0.25s pre-roll（W2 踩坑 3，防丢字头/字尾）。
     * 返回 (段起点样本, 段样本)。
     */
    private fun vadSegments(samples: FloatArray, cfg: VadModelConfig): List<Pair<Long, FloatArray>> {
        val vad = Vad(null, cfg)
        val raw = ArrayList<Pair<Long, Int>>()
        try {
            val chunk = SAMPLE_RATE / 2
            var i = 0
            while (i < samples.size) {
                val end = min(i + chunk, samples.size)
                vad.acceptWaveform(samples.copyOfRange(i, end))
                while (!vad.empty()) {
                    val s = vad.front()
                    raw.add(s.start to s.samples.size)
                    vad.pop()
                }
                i = end
            }
            vad.flush()
            while (!vad.empty()) {
                val s = vad.front()
                raw.add(s.start to s.samples.size)
                vad.pop()
            }
        } finally {
            vad.release()
        }
        val pad = (0.25 * SAMPLE_RATE).toInt()
        return raw.map { (start, n) ->
            val a = max(0L, start - pad).toInt()
            val b = min(samples.size.toLong(), start + n + pad).toInt()
            a.toLong() to samples.copyOfRange(a, b)
        }
    }

    /**
     * 全管线转写（内存 PCM，不落盘）。samples: 16k mono f32 ∈ [-1,1]。
     * hotwordsPath=null 用默认表；useHotwords=false 为热词对照组。
     */
    fun transcribe(
        ctx: Context,
        samples: FloatArray,
        useHotwords: Boolean = true,
        hotwordsPath: String? = null,
    ): Result {
        val (rec, vcfg) = requireReady()
        val t0 = System.currentTimeMillis()

        val tv0 = System.currentTimeMillis()
        val segs = vadSegments(samples, vcfg)
        val vadMs = System.currentTimeMillis() - tv0

        val speechSeconds = segs.sumOf { it.second.size.toDouble() } / SAMPLE_RATE

        val hotwordsFile = Hotwords.hotwordsFile(ctx, hotwordsPath)
        val entries = if (useHotwords && hotwordsFile != null) {
            Hotwords.parse(hotwordsFile.readText(Charsets.UTF_8))
        } else emptyList()
        val pinyin = if (entries.isNotEmpty()) Hotwords.loadPinyin(ctx) else emptyMap()

        var asrMs = 0L
        var hwMs = 0L
        val rawTexts = ArrayList<String>()
        val finalTexts = ArrayList<String>()
        val allEdits = ArrayList<String>()
        for ((_, seg) in segs) {
            val ta = System.currentTimeMillis()
            val raw = Hotwords.normalizePunct(asrSegment(rec, seg))
            asrMs += System.currentTimeMillis() - ta
            rawTexts.add(raw)

            val th = System.currentTimeMillis()
            val final = if (entries.isNotEmpty()) {
                val (t, edits) = Hotwords.apply(raw, entries, pinyin, useHomophone = true)
                allEdits.addAll(edits)
                t
            } else raw
            hwMs += System.currentTimeMillis() - th
            finalTexts.add(final)
        }

        val text = finalTexts.joinToString("")
        val rawText = rawTexts.joinToString("")
        val han = text.count { it in '\u4e00'..'\u9fff' }

        // 低置信启发式（W2 pipeline.py 同源，可观测量，非模型后验）
        val (low, reason) = when {
            segs.isEmpty() -> true to "no_speech_detected"
            text.isEmpty() -> true to "empty_transcription"
            han == 0 -> true to "no_han_characters"
            speechSeconds > 0 && han / speechSeconds < 0.25 -> true to "low_char_density"
            else -> false to "ok"
        }
        val confidence =
            if (speechSeconds <= 0) 0f
            else (han / (4.5 * speechSeconds)).coerceIn(0.0, 1.0).toFloat()

        return Result(
            text = text,
            rawText = rawText,
            lowConfidence = low,
            reason = reason,
            confidence = confidence,
            numSegments = segs.size,
            speechSeconds = speechSeconds.toFloat(),
            vadMs = vadMs,
            asrMs = asrMs,
            hotwordMs = hwMs,
            elapsedMs = System.currentTimeMillis() - t0,
            segments = finalTexts,
            edits = allEdits,
        )
    }

    /**
     * 边说边切段的流式会话（PTT 按住期间的实时滚动数据源，也是最终转写的唯一路径）：
     * 0.5s 块喂入 VAD，完成段**带 0.25s pre-roll 立即转写**（切片与 [transcribe] 的
     * vadSegments 完全同构 → 滚动文本 == 最终上屏文本，且松开无需重转写，NFR2 有保障）。
     */
    class LiveSession {
        private val rec: OfflineRecognizer
        private val vad: Vad
        private val chunks = ArrayList<FloatArray>() // 内存缓冲（会话级，结束即弃，不落盘）
        private var fedTotal = 0L

        /** 已吐出段的切片采样数累计（低置信启发式用；与 [transcribe] 的 speechSeconds 同口径）。 */
        var speechSamples: Long = 0L
            private set

        init {
            val (r, cfg) = requireReady()
            rec = r
            vad = Vad(null, cfg)
        }

        /** 喂入一块 PCM（≤0.5s 为宜），返回本批新完成段（pre-roll 后）转写文本。 */
        fun feed(chunk: FloatArray): List<String> {
            val out = ArrayList<String>()
            vad.acceptWaveform(chunk)
            chunks.add(chunk)
            fedTotal += chunk.size
            while (!vad.empty()) {
                val s = vad.front()
                val slice = sliceWithPad(s.start, s.samples.size)
                speechSamples += slice.size
                out.add(Hotwords.normalizePunct(asrSegment(rec, slice)))
                vad.pop()
            }
            return out
        }

        /** 收尾：吐出残留段（松开时调用）。 */
        fun finish(): List<String> {
            val out = ArrayList<String>()
            vad.flush()
            while (!vad.empty()) {
                val s = vad.front()
                val slice = sliceWithPad(s.start, s.samples.size)
                speechSamples += slice.size
                out.add(Hotwords.normalizePunct(asrSegment(rec, slice)))
                vad.pop()
            }
            vad.release()
            return out
        }

        fun abandon() {
            try {
                vad.release()
            } catch (_: Throwable) {
            }
        }

        /** [start, start+n) 前后各扩 0.25s pre-roll（W2 踩坑 3：防丢字头/字尾）。 */
        private fun sliceWithPad(start: Long, n: Int): FloatArray {
            val pad = (0.25 * SAMPLE_RATE).toLong()
            val a = max(0L, start - pad)
            val b = min(fedTotal, start + n + pad)
            val len = (b - a).toInt()
            val out = FloatArray(len)
            var done = 0
            var offset = 0L
            for (c in chunks) {
                val cStart = offset
                val cEnd = offset + c.size
                val s = max(a, cStart)
                val e = min(b, cEnd)
                if (e > s) {
                    System.arraycopy(c, (s - cStart).toInt(), out, (s - a).toInt(), (e - s).toInt())
                    done += (e - s).toInt()
                }
                offset = cEnd
                if (offset >= b) break
            }
            return if (done == len) out else out.copyOf(done)
        }
    }
}
