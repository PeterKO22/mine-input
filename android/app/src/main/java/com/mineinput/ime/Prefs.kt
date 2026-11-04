package com.mineinput.ime

import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import com.mineinput.ime.sync.SyncStore
import org.json.JSONObject
import java.security.MessageDigest

/**
 * W11 本地状态：知情同意（FR8 逐项显式，默认全关）/ 配对 / 设置开关 / 熔断。
 * 三份 SharedPreferences：w11-consent · w11-pairing · w11-settings。
 */
object Prefs {

    // ---- 知情同意（FR8：高敏采集逐项显式同意，无默认全开；随时可撤回） ----

    class Consent(ctx: Context) {
        private val sp: SharedPreferences =
            ctx.applicationContext.getSharedPreferences("w11-consent", Context.MODE_PRIVATE)

        var c0: Boolean
            get() = sp.getBoolean("c0", false)          // C0 基础上下文（默认关）
            set(v) = sp.edit().putBoolean("c0", v).apply()

        var c2: Boolean
            get() = sp.getBoolean("c2", false)          // C2 读屏上下文（高敏，默认关）
            set(v) = sp.edit().putBoolean("c2", v).apply()

        var hotword: Boolean
            get() = sp.getBoolean("hotword", false)     // 语音热词同步（默认关）
            set(v) = sp.edit().putBoolean("hotword", v).apply()

        val consentedAt: Long get() = sp.getLong("consented_at", 0L)

        val any: Boolean get() = c0 || c2 || hotword

        val all: Boolean get() = c0 && c2 && hotword

        fun touch() = sp.edit().putLong("consented_at", System.currentTimeMillis()).apply()

        fun withdrawAll() {
            sp.edit().putBoolean("c0", false).putBoolean("c2", false).putBoolean("hotword", false).apply()
        }

        var firstLaunchDone: Boolean
            get() = sp.getBoolean("first_launch_done", false)
            set(v) = sp.edit().putBoolean("first_launch_done", v).apply()
    }

    // ---- Hub 配对 ----

    class Pairing(private val ctx: Context) {
        private val sp: SharedPreferences =
            ctx.applicationContext.getSharedPreferences("w11-pairing", Context.MODE_PRIVATE)

        val deviceId: String
            get() = sp.getString("device_id", null) ?: run {
                // 注意：Settings.Secure.ANDROID_ID 是列名常量，须经 contentResolver 取设备值
                val v = Settings.Secure.getString(
                    ctx.applicationContext.contentResolver, Settings.Secure.ANDROID_ID
                ) ?: "unknown"
                val id = "android-$v"
                sp.edit().putString("device_id", id).apply()
                id
            }

        var baseUrl: String
            get() = sp.getString("base_url", "http://10.0.2.2:8088") ?: "http://10.0.2.2:8088"
            set(v) = sp.edit().putString("base_url", v).apply()

        var username: String
            get() = sp.getString("username", "") ?: ""
            set(v) = sp.edit().putString("username", v).apply()

        var token: String?
            get() = sp.getString("token", null)
            set(v) = sp.edit().putString("token", v).apply()

        var userId: Long
            get() = sp.getLong("user_id", -1L)
            set(v) = sp.edit().putLong("user_id", v).apply()

        var keyPartitionId: String
            get() = sp.getString("key_partition_id", "") ?: ""
            set(v) = sp.edit().putString("key_partition_id", v).apply()

        var pairedAt: Long
            get() = sp.getLong("paired_at", 0L)
            set(v) = sp.edit().putLong("paired_at", v).apply()

        val paired: Boolean get() = !token.isNullOrEmpty()

        fun unpair() = sp.edit().remove("token").apply()
    }

    // ---- 设置开关（A4 各分区） ----

    class SettingsStore(ctx: Context) {
        private val sp: SharedPreferences =
            ctx.applicationContext.getSharedPreferences("w11-settings", Context.MODE_PRIVATE)

        // 通用
        var keySound: Boolean
            get() = sp.getBoolean("key_sound", false)
            set(v) = sp.edit().putBoolean("key_sound", v).apply()
        var keyVibrate: Boolean
            get() = sp.getBoolean("key_vibrate", true)
            set(v) = sp.edit().putBoolean("key_vibrate", v).apply()
        var perfMode: Boolean // 性能模式：低端机关 glow（design-language §6）
            get() = sp.getBoolean("perf_mode", false)
            set(v) = sp.edit().putBoolean("perf_mode", v).apply()

        // 输入方案
        var emptyCodeCommit: Boolean // FR1 空码顶字（默认关）
            get() = sp.getBoolean("empty_code_commit", false)
            set(v) = sp.edit().putBoolean("empty_code_commit", v).apply()

        // W24：中/EN 输入模式（持久状态：跨会话保留，密码框自动 EN 不落盘）
        // commit() 同步落盘：force-stop 硬杀进程时 apply() 的异步写会丢（W24 e2e 实测）
        var imeMode: String
            get() = sp.getString("ime_mode", "cn") ?: "cn"
            set(v) {
                sp.edit().putString("ime_mode", v).commit()
            }

        // 自适应学习（L1 词典 / L2 词频习惯）
        var learnL1: Boolean
            get() = sp.getBoolean("learn_l1", true)
            set(v) = sp.edit().putBoolean("learn_l1", v).apply()
        var learnL2: Boolean
            get() = sp.getBoolean("learn_l2", true)
            set(v) = sp.edit().putBoolean("learn_l2", v).apply()

        // 熔断（FR8 一键熔断：立即停止一切采集与上报）
        var fuseBlown: Boolean
            get() = sp.getBoolean("fuse_blown", false)
            set(v) = sp.edit().putBoolean("fuse_blown", v).apply()

        var lastSyncAt: Long
            get() = sp.getLong("last_sync_at", 0L)
            set(v) = sp.edit().putLong("last_sync_at", v).apply()
    }

    /** 配对码 → 确定性凭据（同一配对码 = 同一 Hub 账户，多设备同码即同账号配对）。
     *  也接受 `用户名:密码` 直接凭据（Hub W4 只有 register/token，无一次性配对码端点）。 */
    fun credentialsFromPairingCode(input: String): Pair<String, String>? {
        val code = input.trim()
        if (code.isEmpty()) return null
        if (code.contains(':')) {
            val i = code.indexOf(':')
            val u = code.substring(0, i).trim()
            val p = code.substring(i + 1).trim()
            if (u.isEmpty() || p.isEmpty()) return null
            return u to p
        }
        val seed = code.lowercase().filter { it.isLetterOrDigit() }
        if (seed.length < 4) return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("mine-input.pair.v1:$seed".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "pair-$seed" to ("mi1." + digest.take(24))
    }

    fun exportJson(ctx: Context, consent: Consent, pairing: Pairing, store: SyncStore, queueDepth: Int): JSONObject {
        return JSONObject()
            .put("exported_at", System.currentTimeMillis())
            .put("device_id", pairing.deviceId)
            .put("hub", pairing.baseUrl)
            .put("user_id", pairing.userId)
            .put("key_partition_id", pairing.keyPartitionId)
            .put(
                "consent",
                JSONObject()
                    .put("c0", consent.c0).put("c2", consent.c2).put("hotword", consent.hotword)
                    .put("consented_at", consent.consentedAt)
            )
            .put("userdb", store.userdb())
            .put("pending_counters", store.pendingCounters())
            .put("server_counters", store.serverCounters())
            .put("hotwords", org.json.JSONArray().also { arr -> store.hotwords().forEach { arr.put(it) } })
            .put("schema_version", store.schemaVersion())
            .put("offline_queue_depth", queueDepth)
    }
}
