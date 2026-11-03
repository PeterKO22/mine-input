/*
 * mine-input W16 — 引擎进程级入口（IMS 与 DebugReceiver 钩子共用同一引擎实例）。
 * 首次启动：assets/rime/{shared,user} 落盘（缺则拷，不覆盖既有 userdb 学习数据）
 *   → startupRime(fullCheck=true) 设备端编译码表（首用 ≤5s 验收项）→ selectRimeSchema。
 * 其后启动：fullCheck=false（增量部署）。
 */
package com.mineinput.ime.engine

import android.content.Context
import android.util.Log
import java.io.File

object MixedEngine {
    const val TAG = RimeMixedEngine.TAG

    val engine = RimeMixedEngine()

    @Volatile
    var state: String = "idle" // idle | deploying | ready | failed

    /** 首用部署耗时（startupRime → schema 可选中），报告用。 */
    @Volatile
    var lastDeployMs: Long = -1

    @Volatile
    var lastFirstRun: Boolean = false

    private val lock = Any()

    /**
     * 幂等启动（阻塞）：任意线程可调；native 调用在引擎单线程内串行。
     * 返回 true=引擎就绪（schema ping_wubi_mixed 可选中）。
     */
    fun ensureStarted(ctx: Context, log: (String) -> Unit = { Log.i(TAG, it) }): Boolean {
        synchronized(lock) {
            if (engine.isStarted) return true
            state = "deploying"
            val app = ctx.applicationContext
            val shared = File(app.filesDir, "rime_shared")
            val user = File(app.filesDir, "rime_user")
            val staged = stageAssets(app, shared, user)
            val firstRun = !File(user, ".w16-deployed").exists()
            lastFirstRun = firstRun
            log("STARTUP stage=$staged shared=${shared.list()?.size ?: 0} files first_run=$firstRun")
            val t0 = System.currentTimeMillis()
            val ok = try {
                engine.startup(shared, user, fullCheck = firstRun)
            } catch (t: Throwable) {
                log("STARTUP FAILED ${t.javaClass.simpleName}: ${t.message}")
                state = "failed"
                return false
            }
            lastDeployMs = System.currentTimeMillis() - t0
            state = if (ok) "ready" else "failed"
            if (ok) File(user, ".w16-deployed").writeText(RimeMixedEngine.VERSION)
            log(
                "STARTUP ok=$ok deploy_ms=${lastDeployMs} first_run=$firstRun " +
                    "schema=${engine.status().schemaId} deploy_msgs=${deployMsgs()}",
            )
            return ok
        }
    }

    fun deployMsgs(): String = synchronized(engine.deployMessages) {
        engine.deployMessages.joinToString(" ")
    }

    /** assets/rime/{shared,user} → filesDir；只补缺失文件（保护 userdb 学习数据）。 */
    private fun stageAssets(ctx: Context, shared: File, user: File): String {
        shared.mkdirs()
        user.mkdirs()
        var copied = 0
        fun copyDir(assetPath: String, dst: File) {
            val names = ctx.assets.list(assetPath) ?: return
            for (n in names) {
                val child = "$assetPath/$n"
                val out = File(dst, n)
                val sub = ctx.assets.list(child)
                if (sub != null && sub.isNotEmpty()) {
                    out.mkdirs()
                    copyDir(child, out)
                } else if (!out.exists()) {
                    ctx.assets.open(child).use { input ->
                        out.outputStream().use { output -> input.copyTo(output) }
                    }
                    copied++
                }
            }
        }
        copyDir("rime/shared", shared)
        copyDir("rime/user", user)
        return "copied=$copied"
    }
}
