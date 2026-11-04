package com.mineinput.ime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.mineinput.ime.sync.SyncManager
import org.json.JSONObject

/**
 * W11 端到端调试通道（仅 debug 包生效，release 忽略）：
 *   adb shell am broadcast -a com.mineinput.ime.DEBUG_ACTION --es cmd <cmd> ...
 * cmd:
 *   status                      → 打印同意/配对/熔断/队列状态（W11: STATUS ...）
 *   consent --es c0 1 --es c2 0 --es hotword 1   → 设置同意项（W11: CONSENT_SET ...）
 *   withdraw                    → 撤回全部同意 + 清队列（W11: CONSENT_WITHDRAWN）
 *   seed                        → 写入演示学习数据（userdb/counters/hotword）
 *   sync                        → 立即同步（W11: ROUNDTRIP_OK/FAIL ...）
 *   ingest                      → 模拟一条 candidate_pick 交互事件上报
 *   w14_*                       → W14 语音钩子（w14_status/w14_model/w14_asr/w14_ptt/w14_rec，
 *                                 见 voice/W14Debug.kt；结果打 tag=W14 供 w14-e2e 断言）
 *   w16_*                       → W16 混输引擎钩子（w16_startup/w16_status/w16_seq/w16_commit/
 *                                 w16_learn/w16_bench，见 engine/W16Debug.kt；结果打 tag=W16 供 w16-e2e 断言）
 *   w24_*                       → W24 中/EN 直输与密码框隐私钩子（w24_status/w24_mode/w24_type/
 *                                 w24_pick/w24_fieldtext/w24_layout/w24_collect_probe/w24_aimark，
 *                                 见 W24Debug.kt；结果打 tag=W24 供 w24-e2e 断言）
 * 所有结果打 logcat（tag=W11 / W14 / W16），供 w11-e2e.sh / w14-e2e / w16-e2e 抓取断言。
 */
class DebugReceiver : BroadcastReceiver() {

    override fun onReceive(ctx: Context, intent: Intent) {
        if (ctx.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            return // release 包不响应
        }
        SyncManager.init(ctx)
        val cmd = intent.getStringExtra("cmd") ?: ""
        if (cmd.startsWith("w14_")) {
            // W14 语音钩子（(d) 推 WAV → 转写/上屏确定性断言），实现见 voice/W14Debug.kt
            com.mineinput.ime.voice.W14Debug.handle(ctx, intent)
            return
        }
        if (cmd.startsWith("w16_")) {
            // W16 混输引擎钩子（键序列→候选/上屏/词频/延迟断言），实现见 engine/W16Debug.kt
            com.mineinput.ime.engine.W16Debug.handle(ctx, intent)
            return
        }
        if (cmd.startsWith("w24_")) {
            // W24 中/EN 直输 + 密码框隐私钩子（模式/按键路径/采集闸断言），实现见 W24Debug.kt
            com.mineinput.ime.W24Debug.handle(ctx, intent)
            return
        }
        val pending = goAsync()
        Thread {
            try {
                when (cmd) {
                    "status" -> {
                        val consent = Prefs.Consent(ctx)
                        val pairing = Prefs.Pairing(ctx)
                        val settings = Prefs.SettingsStore(ctx)
                        Log.i(
                            SyncManager.TAG,
                            "STATUS paired=${pairing.paired} hub=${pairing.baseUrl} user_id=${pairing.userId} " +
                                "consent(c0=${consent.c0},c2=${consent.c2},hotword=${consent.hotword}) " +
                                "fuse=${settings.fuseBlown} queue=${SyncManager.queue.depth()} " +
                                "userdb=${SyncManager.store.userdb().length()} " +
                                "pending_counters=${SyncManager.store.pendingCounters()} " +
                                "server_counters=${SyncManager.store.serverCounters()} " +
                                "hotwords=${SyncManager.store.hotwords()} devices=${SyncManager.store.devices()}"
                        )
                    }
                    "consent" -> {
                        val consent = Prefs.Consent(ctx)
                        intent.getStringExtra("c0")?.let { consent.c0 = it == "1" }
                        intent.getStringExtra("c2")?.let { consent.c2 = it == "1" }
                        intent.getStringExtra("hotword")?.let { consent.hotword = it == "1" }
                        consent.touch()
                        Log.i(SyncManager.TAG, "CONSENT_SET c0=${consent.c0} c2=${consent.c2} hotword=${consent.hotword}")
                    }
                    "withdraw" -> {
                        Prefs.Consent(ctx).withdrawAll()
                        SyncManager.queue.clear()
                        Log.i(SyncManager.TAG, "CONSENT_WITHDRAWN all=false queue_cleared")
                    }
                    "seed" -> {
                        val now = System.currentTimeMillis()
                        val key = intent.getStringExtra("key") ?: "w11/demo"
                        val value = intent.getStringExtra("value") ?: "hello-w11"
                        val counter = intent.getStringExtra("counter") ?: "w11_clicks"
                        val delta = intent.getStringExtra("delta")?.toLongOrNull()
                            ?: intent.getLongExtra("delta", 3L)
                        val hotword = intent.getStringExtra("hotword") ?: "W11热词"
                        SyncManager.store.putUserdb(key, value, now)
                        SyncManager.store.addCounter(counter, delta)
                        SyncManager.store.addHotword(hotword)
                        Log.i(SyncManager.TAG, "SEEDED key=$key value=$value counter=$counter delta=$delta hotword=$hotword")
                    }
                    "sync" -> {
                        val r = SyncManager.syncNowAndLog("debug-cmd")
                        Log.i(
                            SyncManager.TAG,
                            if (r.blocked) "SYNC_RESULT blocked=${r.blockReason}"
                            else "SYNC_RESULT push=${r.pushStatus} push_id=${r.pushId} pull=${r.pullOk} roundtrip=${r.roundtrip} detail=${r.roundtripDetail}"
                        )
                    }
                    "ingest" -> {
                        val now = System.currentTimeMillis()
                        val ev = JSONObject()
                            .put("ts", now)
                            .put("device_id", Prefs.Pairing(ctx).deviceId)
                            .put("app_id", "com.mineinput.ime")
                            .put("kind", "candidate_pick")
                            .put("text_in", intent.getStringExtra("text_in") ?: "debug")
                            .put("text_out", intent.getStringExtra("text_out") ?: "调试上屏")
                            .put("keystroke_cadence", 3.2)
                            .put("suggestion_shown", 2)
                            .put("suggestion_taken", 1)
                        val res = SyncManager.recordInteraction(ev)
                        Log.i(SyncManager.TAG, "INGEST_RESULT $res")
                    }
                    "pair" -> {
                        val code = intent.getStringExtra("code") ?: ""
                        val hub = intent.getStringExtra("hub")
                        if (!hub.isNullOrBlank()) Prefs.Pairing(ctx).baseUrl = hub
                        val res = SyncManager.pair(code)
                        Log.i(SyncManager.TAG, "PAIR_RESULT $res")
                    }
                    else -> Log.i(SyncManager.TAG, "UNKNOWN_CMD $cmd")
                }
            } catch (e: Exception) {
                Log.i(SyncManager.TAG, "CMD_ERROR cmd=$cmd ${e.message}")
            } finally {
                pending.finish()
            }
        }.start()
    }
}
