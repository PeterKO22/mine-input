/*
 * mine-input W24 — DebugReceiver 测试钩子（仅 debug 包；结果打 logcat tag=W24 供 w24-e2e.py 断言）。
 *
 * 命令（adb shell am broadcast -n com.mineinput.ime/.DebugReceiver -a com.mineinput.ime.DEBUG_ACTION --es cmd ...）：
 *   w24_status                        → STATUS|mode=|password_field=|collection=|raw=|composing=|demo_ai=|bound=
 *   w24_mode   --es mode en|cn|toggle → MODE|mode=|persisted=|ok=（与工具栏「中/EN」键同一 handler）
 *   w24_type   --es text hello        → 逐字符走 MineImeService 真实按键路径（onLetter/onDirect/onSpace/…），
 *                                       TYPE|text=|dispatched=|mode=|via=input-connection + CANDS|（中文态候选）
 *   w24_pick   --es index 0           → PICK|index=|text=|via=input-connection（点选候选上屏）
 *   w24_fieldtext --es which normal   → FIELD|which=|text=|active=（进程内读探针输入框文本）
 *   w24_layout                       → MODE_CHIP|x=|y=|w=|h=（「中/EN」键屏幕坐标，e2e 真实点按）
 *   w24_collect_probe                → 采集探针（密码框应 COLLECT_BLOCKED；正常框走 W11 上报链路）
 *   w24_aimark --es n 2              → AI 智能候选组标记演示（前 n 候选标 AI；AI_MARK|n=|applied=）
 */
package com.mineinput.ime

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.mineinput.ime.engine.MixedEngine
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object W24Debug {
    const val TAG = "W24"

    fun handle(ctx: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd") ?: ""
        Thread({
            try {
                run(intent, cmd)
            } catch (t: Throwable) {
                Log.i(TAG, "CMD_ERROR cmd=$cmd ${t.javaClass.simpleName}: ${t.message}")
            }
        }, "w24-debug").start()
    }

    /** InputConnection/视图操作一律回主线程执行并等完成（后续读取才可见）。 */
    private fun <T> onMain(block: () -> T): T {
        val latch = CountDownLatch(1)
        var result: T? = null
        Handler(Looper.getMainLooper()).post {
            try {
                result = block()
            } finally {
                latch.countDown()
            }
        }
        latch.await(10, TimeUnit.SECONDS)
        @Suppress("UNCHECKED_CAST")
        return result as T
    }

    private fun run(intent: Intent, cmd: String) {
        val svc = MineImeService.active
        if (svc == null) {
            Log.i(TAG, "SERVICE_NOT_READY cmd=$cmd")
            return
        }
        when (cmd) {
            "w24_status" -> {
                val st = onMain {
                    Triple(svc.mode(), svc.inPasswordField(), svc.modeChipBounds() != null)
                }
                val engine = MixedEngine.engine
                Log.i(
                    TAG,
                    "STATUS|mode=${st.first}|password_field=${st.second}" +
                        "|collection=${if (st.second) "paused" else "on"}" +
                        "|raw=${if (engine.isStarted) engine.rawInput() else ""}" +
                        "|demo_ai=${svc.demoAi()}|keyboard=${st.third}",
                )
            }

            "w24_mode" -> {
                val want = intent.getStringExtra("mode") ?: "toggle"
                val ok = onMain {
                    when (want) {
                        "toggle" -> svc.toggleMode()
                        else -> svc.setMode(want == "en")
                    }
                }
                val persisted = Prefs.SettingsStore(svc).imeMode
                Log.i(TAG, "MODE|mode=${svc.mode()}|persisted=$persisted|ok=$ok|want=$want")
            }

            "w24_type" -> {
                val text = intent.getStringExtra("text") ?: ""
                val dispatched = onMain {
                    var n = 0
                    for (ch in text) {
                        when {
                            ch == ' ' -> svc.onSpace()
                            ch == '\b' -> svc.onDelete()
                            ch == '\n' -> svc.onEnter()
                            ch.isLetter() || ch == '，' || ch == '。' -> svc.onLetter(ch)
                            else -> svc.onDirect(ch)
                        }
                        n++
                    }
                    n
                }
                Log.i(
                    TAG,
                    "TYPE|text=$text|dispatched=$dispatched|mode=${svc.mode()}" +
                        "|password_field=${svc.inPasswordField()}|via=input-connection",
                )
                if (svc.mode() == "cn") {
                    val cands = if (MixedEngine.engine.isStarted) MixedEngine.engine.candidates(0, 8) else emptyList()
                    val sb = StringBuilder("CANDS|n=${cands.size}")
                    cands.forEachIndexed { i, c -> sb.append("|").append(i + 1).append("=").append(c.text) }
                    Log.i(TAG, sb.toString())
                }
            }

            "w24_pick" -> {
                val index = intent.getStringExtra("index")?.toIntOrNull() ?: 0
                val text = onMain { svc.commitCandidate(index) }
                Log.i(TAG, "PICK|index=$index|text=$text|via=input-connection|ok=${text.isNotEmpty()}")
            }

            "w24_fieldtext" -> {
                val which = intent.getStringExtra("which") ?: "normal"
                val text = W24ProbeActivity.fieldText(which)
                Log.i(TAG, "FIELD|which=$which|text=${text ?: ""}|active=${W24ProbeActivity.active != null}")
            }

            "w24_layout" -> {
                val r = onMain { svc.modeChipBounds() }
                if (r == null) Log.i(TAG, "MODE_CHIP|ready=false")
                else Log.i(TAG, "MODE_CHIP|ready=true|x=${r.centerX()}|y=${r.centerY()}|w=${r.width()}|h=${r.height()}")
            }

            "w24_collect_probe" -> {
                onMain { svc.collectProbe() }
                Log.i(TAG, "COLLECT_PROBE|done|password_field=${svc.inPasswordField()}")
            }

            "w24_aimark" -> {
                val n = intent.getStringExtra("n")?.toIntOrNull() ?: 0
                onMain { svc.setDemoAiCount(n) }
                Log.i(TAG, "AI_MARK|n=$n|applied=true")
            }

            else -> Log.i(TAG, "UNKNOWN_CMD $cmd")
        }
    }
}
