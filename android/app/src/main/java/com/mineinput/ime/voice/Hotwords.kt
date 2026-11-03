package com.mineinput.ime.voice

import android.content.Context
import java.io.File

/**
 * W14 热词后处理（与 voice/mic/pipeline.py `apply_hotwords` 同源语义）：
 *   1) 显式别名替换：别名出现在转写中 → 直接替换为正词（长别名优先）；
 *   2) 同音窗口匹配：转写中任意与正词同音（无声调拼音）的连续汉字段 → 替换为正词。
 * 热词只纠偏、不改写：转写已正确时不产生任何变化。
 *
 * hotwords.txt 格式：每行 `正词 [显式别名1 别名2 ...]`，`#` 注释，空行忽略。
 * 默认表由 assets/voice/hotwords.txt 首次播种到 filesDir/voice/hotwords.txt（人工可编辑）。
 *
 * 同音匹配用逐字拼音表 assets/voice/pinyin.txt（pypinyin 默认读音生成，无声调）：
 * 逐字查表，多音字取默认读音——语境消歧弱于 W2 的 lazy_pinyin 词级分词，报告已注明。
 */
object Hotwords {

    data class Entry(val canonical: String, val aliases: Set<String>)

    /** hotwords.txt 文本 → 热词条目。 */
    fun parse(text: String): List<Entry> =
        text.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .mapNotNull { line ->
                val toks = line.split(Regex("\\s+"))
                val canonical = toks.firstOrNull() ?: return@mapNotNull null
                Entry(canonical, toks.drop(1).filter { it.isNotEmpty() && it != canonical }.toSet())
            }
            .toList()

    /** 热词表文件：filesDir/voice/hotwords.txt（不存在则从 assets 播种默认表）。 */
    fun hotwordsFile(ctx: Context, overridePath: String? = null): File? {
        if (overridePath != null) {
            val f = File(overridePath)
            return if (f.exists()) f else null
        }
        val dir = File(ctx.filesDir, "voice")
        val f = File(dir, "hotwords.txt")
        if (!f.exists()) {
            try {
                dir.mkdirs()
                ctx.assets.open("voice/hotwords.txt").use { input ->
                    f.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Throwable) {
                return null
            }
        }
        return f
    }

    /** 逐字拼音表：char → 无声调拼音（多音字取 pypinyin 默认读音）。 */
    fun loadPinyin(ctx: Context): Map<Char, String> {
        val map = HashMap<Char, String>(22000)
        try {
            ctx.assets.open("voice/pinyin.txt").bufferedReader(Charsets.UTF_8).useLines { lines ->
                for (line in lines) {
                    val t = line.trim()
                    if (t.isEmpty() || t.startsWith("#")) continue
                    val sp = t.lastIndexOf(' ')
                    if (sp <= 0 || sp == t.length - 1) continue
                    val ch = t[0]
                    if (ch.code > 0x3000 && sp == 1) map[ch] = t.substring(2)
                }
            }
        } catch (_: Throwable) {
        }
        return map
    }

    private fun isHan(ch: Char): Boolean = ch in '\u4e00'..'\u9fff'

    private fun pinyinOf(text: String, pinyin: Map<Char, String>): List<String>? {
        val out = ArrayList<String>(text.length)
        for (ch in text) {
            out.add(pinyin[ch] ?: return null) // 表外字 → 无法比较
        }
        return out
    }

    /**
     * 纠偏。返回 (结果文本, 编辑记录)。useHomophone=false 时只做显式别名替换。
     */
    fun apply(
        text: String,
        entries: List<Entry>,
        pinyin: Map<Char, String>,
        useHomophone: Boolean = true,
    ): Pair<String, List<String>> {
        var out = text
        val edits = mutableListOf<String>()

        // 1) 显式别名替换（长别名优先，与 W2 同序）
        for (e in entries) {
            for (alias in e.aliases.sortedByDescending { it.length }) {
                if (alias.isNotEmpty() && alias != e.canonical && alias in out) {
                    out = out.replace(alias, e.canonical)
                    edits.add("别名替换: $alias→${e.canonical}")
                }
            }
        }

        if (!useHomophone) return out to edits

        // 2) 同音窗口匹配（贪心从左到右，窗口长 = 正词长，与 W2 逐位扫描一致）
        for (e in entries) {
            if (e.canonical.isEmpty() || !isHan(e.canonical[0])) continue
            val want = pinyinOf(e.canonical, pinyin) ?: continue
            val L = e.canonical.length
            if (L == 0) continue
            val sb = StringBuilder()
            var i = 0
            while (i < out.length) {
                if (isHan(out[i]) && i + L <= out.length) {
                    val window = out.substring(i, i + L)
                    if (window.all { isHan(it) } && window != e.canonical &&
                        pinyinOf(window, pinyin) == want
                    ) {
                        sb.append(e.canonical)
                        edits.add("同音替换: $window→${e.canonical}")
                        i += L
                        continue
                    }
                }
                sb.append(out[i])
                i++
            }
            out = sb.toString()
        }
        return out to edits
    }

    private val PUNCT_RUN = Regex("([，。！？；、,.!?;:]){2,}")

    /** 连续标点串合并（优先保留 。！？），与 W2 normalize_punct 同源。 */
    fun normalizePunct(text: String): String =
        PUNCT_RUN.replace(text) { m ->
            val run = m.value
            val terminal = "。！？.!?" firstOrNull { it in run }
            if (terminal != null) terminal.toString() else run[0].toString()
        }
}

private infix fun String.firstOrNull(pred: (Char) -> Boolean): Char? {
    for (c in this) if (pred(c)) return c
    return null
}
