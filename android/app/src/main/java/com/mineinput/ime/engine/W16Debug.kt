/*
 * mine-input W16 — DebugReceiver 测试钩子（仅 debug 包；结果打 logcat tag=W16 供 w16-e2e.py 断言）。
 *
 * 命令（adb shell am broadcast -n com.mineinput.ime/.DebugReceiver -a com.mineinput.ime.DEBUG_ACTION --es cmd ...）：
 *   w16_startup                        → 启动/部署引擎（首用编译码表；STARTUP|deploy_ms=...）
 *   w16_status                         → STATUS|state=...|schema=...|raw=...|cands=...
 *   w16_seq    --es seq w [--es expect 人] [--es page 8]
 *                                      → RESULT|seq=|input=|n=|1=人()|... + SEQ_MS|key_to_cand_ms=
 *                                        + EXPECT|match=（首候选断言；注释=() 前为 text，括号内为 z 反查注释）
 *   w16_commit --es seq gggg [--es index 0] [--es expect 王]
 *                                      → 打序列→点选候选→W5 commit 通道上屏
 *                                        COMMIT|seq=|index=|text=|via=input-connection|match=
 *   w16_learn  [--es seq gggg] [--es index 2]
 *                                      → L1 词频/造词：点选第 index 候选后重打同码
 *                                        LEARN|picked=|before_rank=|after_rank=|direct=|after1=
 *   w16_bench  [--es n 100] [--es seq gggg]
 *                                      → NFR1 按键→候选延迟（含单线程排队+processRimeKey+getRimeCandidates）
 *                                        BENCH|n=|avg_ms=|p50_ms=|p95_ms=|max_ms=|limit_ms=30|pass=
 */
package com.mineinput.ime.engine

import android.content.Context
import android.content.Intent
import android.util.Log
import com.mineinput.ime.MineImeService

object W16Debug {
    const val TAG = "W16"

    fun handle(ctx: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd") ?: ""
        Thread({
            try {
                run(ctx, intent, cmd)
            } catch (t: Throwable) {
                Log.i(TAG, "CMD_ERROR cmd=$cmd ${t.javaClass.simpleName}: ${t.message}")
            }
        }, "w16-debug").start()
    }

    private fun run(ctx: Context, intent: Intent, cmd: String) {
        val engine = MixedEngine.engine
        if (!MixedEngine.ensureStarted(ctx) { Log.i(TAG, it) }) {
            Log.i(TAG, "ENGINE_NOT_READY cmd=$cmd state=${MixedEngine.state}")
            return
        }
        when (cmd) {
            "w16_startup" -> Log.i(
                TAG,
                "STARTUP|ok=true|deploy_ms=${MixedEngine.lastDeployMs}|first_run=${MixedEngine.lastFirstRun}" +
                    "|schema=${engine.status().schemaId}",
            )

            "w16_status" -> {
                val st = engine.status()
                Log.i(
                    TAG,
                    "STATUS|state=${MixedEngine.state}|schema=${st.schemaId}|composing=${st.isComposing}" +
                        "|ascii=${st.isAsciiMode}|raw=${engine.rawInput()}|deploy_ms=${MixedEngine.lastDeployMs}" +
                        "|first_run=${MixedEngine.lastFirstRun}|deploy_msgs=${MixedEngine.deployMsgs()}",
                )
            }

            "w16_seq" -> {
                val seq = intent.getStringExtra("seq") ?: "w"
                val expect = intent.getStringExtra("expect")
                val page = intent.getStringExtra("page")?.toIntOrNull() ?: 8
                engine.clear()
                var keyNs = 0L
                var cands = emptyList<EngineCandidate>()
                for (ch in seq) {
                    val t0 = System.nanoTime()
                    cands = engine.onLetter(ch)
                    keyNs += System.nanoTime() - t0
                }
                val input = engine.rawInput()
                val sb = StringBuilder("RESULT|seq=$seq|input=$input|n=${cands.size}")
                cands.take(page).forEachIndexed { i, c ->
                    sb.append("|").append(i + 1).append("=").append(c.text).append("(").append(c.comment).append(")")
                }
                Log.i(TAG, sb.toString())
                Log.i(
                    TAG,
                    "SEQ_MS|seq=$seq|keys=${seq.length}|key_to_cand_ms=${"%.3f".format(keyNs / 1e6)}" +
                        "|per_key_ms=${"%.3f".format(keyNs / 1e6 / seq.length)}",
                )
                if (expect != null) {
                    val got = cands.firstOrNull()?.text ?: ""
                    Log.i(TAG, "EXPECT|seq=$seq|expect=$expect|got=$got|match=${got == expect}")
                }
            }

            "w16_commit" -> {
                val seq = intent.getStringExtra("seq") ?: "gggg"
                val index = intent.getStringExtra("index")?.toIntOrNull() ?: 0
                val expect = intent.getStringExtra("expect")
                engine.clear()
                for (ch in seq) engine.onLetter(ch)
                val before = engine.candidates(0, 8)
                val picked = before.getOrNull(index)?.text ?: ""
                val text = engine.commit(index)
                val via = commitThroughIme(ctx, text)
                Log.i(
                    TAG,
                    "COMMIT|seq=$seq|index=$index|picked=$picked|text=$text|via=$via" +
                        (if (expect != null) "|expect=$expect|match=${text == expect}" else ""),
                )
            }

            "w16_learn" -> {
                // L1 词频/造词（两段自足式，可重入）：
                //   阶段1：点选第 index 候选 A 上屏 → 重打同码 → A 应前移/直达（词频）
                //   阶段2：点选新第 index 候选 B 上屏 → 重打同码 → B 二次直达（词频）
                //   造词：encode_commit_history 将 A+B 编码成句候选（A+B 应出现在候选栏）
                val seq = intent.getStringExtra("seq") ?: "gggg"
                val index = intent.getStringExtra("index")?.toIntOrNull() ?: 2
                fun type(seq: String): List<EngineCandidate> {
                    engine.clear()
                    var c = emptyList<EngineCandidate>()
                    for (ch in seq) c = engine.onLetter(ch)
                    return c
                }
                val list0 = type(seq)
                val a = list0.getOrNull(index)?.text ?: ""
                val rankA0 = list0.indexOfFirst { it.text == a } + 1
                val textA = engine.commit(index)
                commitThroughIme(ctx, textA)

                val list1 = type(seq)
                val rankA1 = list1.indexOfFirst { it.text == textA } + 1
                Log.i(
                    TAG,
                    "LEARN|seq=$seq|index=$index|picked=$textA|before_rank=$rankA0|after_rank=$rankA1" +
                        "|direct=${rankA1 == 1}|after1=${list1.firstOrNull()?.text ?: ""}" +
                        "|before=${list0.joinToString(",") { it.text }}|after=${list1.joinToString(",") { it.text }}",
                )

                val b = list1.getOrNull(index)?.text ?: ""
                if (b.isEmpty() || b == textA) {
                    Log.i(TAG, "LEARN2|skipped=true|reason=no-distinct-candidate")
                    return
                }
                val rankB0 = list1.indexOfFirst { it.text == b } + 1
                val textB = engine.commit(index)
                commitThroughIme(ctx, textB)

                val list2 = type(seq)
                val rankB1 = list2.indexOfFirst { it.text == textB } + 1
                val phrase = textA + textB
                val phraseFound = list2.any { it.text == phrase }
                Log.i(
                    TAG,
                    "LEARN2|seq=$seq|picked=$textB|before_rank=$rankB0|after_rank=$rankB1" +
                        "|direct=${rankB1 == 1}|after1=${list2.firstOrNull()?.text ?: ""}" +
                        "|after=${list2.joinToString(",") { it.text }}",
                )
                Log.i(
                    TAG,
                    "PHRASE|seq=$seq|text=$phrase|found=$phraseFound" +
                        "|cands=${list2.joinToString(",") { it.text }}",
                )
            }

            "w16_bench" -> {
                val seq = intent.getStringExtra("seq") ?: "gggg"
                val n = intent.getStringExtra("n")?.toIntOrNull() ?: 100
                val lat = ArrayList<Long>(n * seq.length)
                repeat(n) {
                    engine.clear()
                    for (ch in seq) {
                        val t0 = System.nanoTime()
                        engine.onLetter(ch)
                        lat.add(System.nanoTime() - t0)
                    }
                }
                lat.sort()
                fun ms(ns: Long) = "%.3f".format(ns / 1e6)
                val avg = lat.average()
                val p50 = lat[lat.size / 2]
                val p95 = lat[(lat.size * 95) / 100]
                val max = lat.last()
                Log.i(
                    TAG,
                    "BENCH|n=${lat.size}|seq=$seq|avg_ms=${"%.3f".format(avg / 1e6)}|p50_ms=${ms(p50)}" +
                        "|p95_ms=${ms(p95)}|max_ms=${ms(max)}|limit_ms=30|pass=${p95 <= 30_000_000}",
                )
            }

            else -> Log.i(TAG, "UNKNOWN_CMD $cmd")
        }
    }

    /** W5 commit 通道：有活动 IMS 则走 currentInputConnection.commitText。 */
    private fun commitThroughIme(ctx: Context, text: String): String {
        val svc = MineImeService.active ?: return "no-ic"
        return if (svc.commitEngineText(text)) "input-connection" else "no-ic"
    }
}
