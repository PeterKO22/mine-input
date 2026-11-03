package com.mineinput.ime.voice

import android.content.Context
import android.util.Log
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * W14 语音模型管理（(a) 首用下载式，模型不进 APK，SHA256 钉死）。
 *
 * 清单（与 voice/W2-REPORT.md §3 同一产物、同一 SHA256）：
 *   - SenseVoiceSmall int8：GitHub Releases `asr-models` 的 tar.bz2 归档
 *     （下载校验归档 SHA256，解出 model.int8.onnx / tokens.txt 再逐一校验）；
 *   - Silero VAD v4：同 tag 单文件 silero_vad.onnx。
 * 归档解压用纯 Java（commons-compress bzip2/tar）——Android toybox 无 bunzip2。
 * 模型落 filesDir/voice-models/（应用私有目录），下载全程带 SHA256 校验，
 * 校验失败即弃，不产出半成品。音频与模型均不经外置存储。
 */
object ModelManager {

    const val TAG = "W14"

    data class Artifact(
        val name: String,
        val url: String,
        val sha256: String,
        val sizeBytes: Long,
    )

    /** 下载清单（SHA256 全部实测记录，见 W14-REPORT.md §2）。 */
    val SENSE_ARCHIVE = Artifact(
        name = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
        url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
        sha256 = "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e",
        sizeBytes = 163002883L,
    )
    val VAD_MODEL = Artifact(
        name = "silero_vad.onnx",
        url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx",
        sha256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
        sizeBytes = 643854L,
    )

    /** 解压产物校验（解压后逐文件核对）。 */
    val EXTRACTED = mapOf(
        "sense-voice/model.int8.onnx" to "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
        "sense-voice/tokens.txt" to "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
        "silero_vad.onnx" to "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
    )

    fun modelRoot(ctx: Context): File = File(ctx.filesDir, "voice-models")

    fun isInstalled(ctx: Context): Boolean {
        val root = modelRoot(ctx)
        return File(root, "INSTALLED").exists() && EXTRACTED.keys.all { File(root, it).exists() }
    }

    /** 状态行（w14_status 用）。 */
    fun status(ctx: Context): String {
        val root = modelRoot(ctx)
        val files = EXTRACTED.keys.joinToString(",") {
            val f = File(root, it)
            "${it.substringAfterLast('/')}=${if (f.exists()) f.length() else -1}"
        }
        return "installed=${isInstalled(ctx)} $files"
    }

    /**
     * 首用下载 + 校验 + 解压（阻塞式，调用方放工作线程）。返回 true=就绪。
     * 已安装时直接 true；产物已就位且校验通过时跳过重下。
     */
    @Synchronized
    fun install(ctx: Context, log: (String) -> Unit = { Log.i(TAG, it) }): Boolean {
        if (isInstalled(ctx)) {
            log("MODEL_OK already-installed ${status(ctx)}")
            return true
        }
        val root = modelRoot(ctx)
        val cache = File(ctx.cacheDir, "voice-model-dl")
        cache.mkdirs()
        root.mkdirs()
        return try {
            // 1) VAD 单文件
            installSingle(VAD_MODEL, File(root, "silero_vad.onnx"), cache, log)
            // 2) SenseVoice 归档：下载校验 → 解压校验
            val archive = File(cache, SENSE_ARCHIVE.name)
            if (!verifyFile(archive, SENSE_ARCHIVE.sha256)) {
                download(SENSE_ARCHIVE, archive, log)
            }
            log("MODEL_EXTRACT begin ${SENSE_ARCHIVE.name}")
            extractSenseVoice(archive, root, log)
            // 3) 产物逐一校验
            for ((rel, sha) in EXTRACTED) {
                val f = File(root, rel)
                if (!f.exists() || sha256(f) != sha) {
                    log("MODEL_FAIL extracted-checksum $rel")
                    return false
                }
            }
            File(root, "INSTALLED").writeText("ok\n${EXTRACTED.entries.joinToString("\n") { "${it.key} ${it.value}" }}\n")
            log("MODEL_OK ${status(ctx)}")
            true
        } catch (e: Throwable) {
            log("MODEL_FAIL ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    /** 测试钩子：单文件下载 + SHA256 校验（w14_model --es url/--es sha256/--es dest）。 */
    @Synchronized
    fun installOne(ctx: Context, art: Artifact, destRel: String, log: (String) -> Unit): Boolean {
        val root = modelRoot(ctx)
        val cache = File(ctx.cacheDir, "voice-model-dl")
        cache.mkdirs()
        root.mkdirs()
        return try {
            installSingle(art, File(root, destRel), cache, log)
            log("MODEL_OK single name=${art.name} dest=$destRel sha256=${art.sha256}")
            true
        } catch (e: Throwable) {
            log("MODEL_FAIL single name=${art.name} ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    private fun installSingle(art: Artifact, dest: File, cache: File, log: (String) -> Unit) {
        if (dest.exists() && verifyFile(dest, art.sha256)) {
            log("MODEL_SKIP name=${art.name} already-verified")
            return
        }
        val tmp = File(cache, art.name)
        if (!verifyFile(tmp, art.sha256)) {
            download(art, tmp, log)
        }
        dest.parentFile?.mkdirs()
        tmp.copyTo(dest, overwrite = true)
        if (!verifyFile(dest, art.sha256)) {
            dest.delete()
            throw IllegalStateException("checksum mismatch after copy: ${art.name}")
        }
        log("MODEL_FILE name=${art.name} dest=${dest.absolutePath} bytes=${dest.length()} sha256=${art.sha256}")
    }

    /** 流式下载，边下边算 SHA256，校验通过才落定。 */
    private fun download(art: Artifact, dest: File, log: (String) -> Unit) {
        val part = File(dest.parentFile, dest.name + ".part")
        log("MODEL_DL begin name=${art.name} url=${art.url} expect_bytes=${art.sizeBytes} sha256=${art.sha256}")
        val conn = URL(art.url).openConnection() as HttpURLConnection
        conn.connectTimeout = 30000
        conn.readTimeout = 60000
        conn.instanceFollowRedirects = true
        try {
            if (conn.responseCode != 200) throw IllegalStateException("http ${conn.responseCode}")
            val md = MessageDigest.getInstance("SHA-256")
            var total = 0L
            var lastLog = 0L
            conn.inputStream.use { input ->
                FileOutputStream(part).use { fos ->
                    BufferedOutputStream(fos).use { out ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            md.update(buf, 0, n)
                            total += n
                            if (total - lastLog >= 32L * 1024 * 1024) {
                                lastLog = total
                                log("MODEL_DL progress name=${art.name} bytes=$total")
                            }
                        }
                    }
                }
            }
            val got = md.digest().joinToString("") { "%02x".format(it) }
            if (got != art.sha256) {
                part.delete()
                throw IllegalStateException("sha256 mismatch got=$got want=${art.sha256}")
            }
            if (dest.exists()) dest.delete()
            if (!part.renameTo(dest)) {
                part.copyTo(dest, overwrite = true)
                part.delete()
            }
            log("MODEL_DL done name=${art.name} bytes=$total sha256=$got")
        } finally {
            conn.disconnect()
        }
    }

    /** tar.bz2 解出 sense-voice 目录下 model.int8.onnx / tokens.txt（其余条目跳过）。 */
    private fun extractSenseVoice(archive: File, root: File, log: (String) -> Unit) {
        val outDir = File(root, "sense-voice")
        outDir.mkdirs()
        var extracted = 0
        TarArchiveInputStream(
            BZip2CompressorInputStream(BufferedInputStream(FileInputStream(archive)), true)
        ).use { tis ->
            while (true) {
                val entry = tis.nextEntry ?: break
                if (entry.isDirectory) continue
                val name = entry.name
                val base = name.substringAfterLast('/')
                if (base != "model.int8.onnx" && base != "tokens.txt") continue
                val out = File(outDir, base)
                FileOutputStream(out).use { fos ->
                    BufferedOutputStream(fos).use { os ->
                        val buf = ByteArray(1 shl 20)
                        while (true) {
                            val n = tis.read(buf)
                            if (n < 0) break
                            os.write(buf, 0, n)
                        }
                    }
                }
                extracted++
                log("MODEL_EXTRACT file=$name bytes=${out.length()}")
            }
        }
        if (extracted != 2) throw IllegalStateException("extracted=$extracted want=2")
    }

    private fun verifyFile(f: File, sha256: String): Boolean =
        f.exists() && f.length() > 0 && sha256(f) == sha256

    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(f).use { input ->
            BufferedInputStream(input).use { bin ->
                val buf = ByteArray(1 shl 20)
                while (true) {
                    val n = bin.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                }
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
