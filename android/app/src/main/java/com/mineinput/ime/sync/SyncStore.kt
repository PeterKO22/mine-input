package com.mineinput.ime.sync

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * W11 本地同步状态（L1 userdb / L2 计数器增量 / L3 热词 / meta）。
 * 合并语义对齐 W8/Hub：userdb 时间戳取新、计数器增量累加（本地攒增量、
 * 成功上行后扣除已发送增量）、热词集合并、meta 取新。
 */
class SyncStore(ctx: Context) {

    private val sp: SharedPreferences =
        ctx.applicationContext.getSharedPreferences("w11-sync-store", Context.MODE_PRIVATE)

    // ---- userdb：key -> {"value": s, "updated_at": ms} ----

    fun userdb(): JSONObject = json(sp.getString("userdb", null) ?: "{}")

    fun putUserdb(key: String, value: String, updatedAt: Long) {
        val o = userdb()
        o.put(key, JSONObject().put("value", value).put("updated_at", updatedAt))
        sp.edit().putString("userdb", o.toString()).apply()
    }

    /** pull 合并：同 key 取新（updated_at 大者胜）。返回是否有变更。 */
    fun mergeUserdb(entries: List<UserdbEntry>): Boolean {
        if (entries.isEmpty()) return false
        val o = userdb()
        var changed = false
        for (e in entries) {
            val cur = o.optJSONObject(e.key)
            if (cur == null || e.updatedAt >= cur.optLong("updated_at")) {
                o.put(e.key, JSONObject().put("value", e.value).put("updated_at", e.updatedAt))
                changed = true
            }
        }
        if (changed) sp.edit().putString("userdb", o.toString()).apply()
        return changed
    }

    // ---- 计数器：本地待发增量（服务端累加） ----

    fun pendingCounters(): JSONObject = json(sp.getString("pending_counters", null) ?: "{}")

    fun addCounter(name: String, delta: Long) {
        val o = pendingCounters()
        o.put(name, o.optLong(name, 0L) + delta)
        sp.edit().putString("pending_counters", o.toString()).apply()
    }

    /** push 成功（含 duplicate：服务端已计入）后扣除已发送增量。 */
    fun ackCounters(sent: JSONObject) {
        val o = pendingCounters()
        for (k in sent.keys()) {
            val v = o.optLong(k, 0L) - sent.optLong(k)
            if (v <= 0L) o.remove(k) else o.put(k, v)
        }
        sp.edit().putString("pending_counters", o.toString()).apply()
    }

    /** 服务端累计值（pull 同步），用于展示与往返校验。 */
    fun serverCounters(): JSONObject = json(sp.getString("server_counters", null) ?: "{}")

    fun setServerCounters(c: Map<String, Long>) {
        val o = JSONObject()
        for ((k, v) in c) o.put(k, v)
        sp.edit().putString("server_counters", o.toString()).apply()
    }

    // ---- 热词（集合语义） ----

    fun hotwords(): MutableSet<String> =
        (sp.getStringSet("hotwords", emptySet()) ?: emptySet()).toMutableSet()

    fun addHotword(w: String) {
        val s = hotwords()
        s.add(w)
        sp.edit().putStringSet("hotwords", s).apply()
    }

    fun mergeHotwords(ws: List<String>): Boolean {
        val s = hotwords()
        val before = s.size
        s.addAll(ws)
        if (s.size != before) sp.edit().putStringSet("hotwords", s).apply()
        return s.size != before
    }

    // ---- meta（取新） ----

    fun schemaVersion(): JSONObject = json(sp.getString("schema_version", null) ?: "null")

    fun mergeSchemaVersion(meta: JSONObject?) {
        if (meta == null) return
        val cur = schemaVersion()
        if (cur.isNull("updated_at") || meta.optLong("updated_at") >= cur.optLong("updated_at")) {
            sp.edit().putString("schema_version", meta.toString()).apply()
        }
    }

    fun mergeAiConfig(meta: JSONObject?) {
        if (meta == null) return
        val cur = json(sp.getString("ai_config", null) ?: "null")
        if (cur.isNull("updated_at") || meta.optLong("updated_at") >= cur.optLong("updated_at")) {
            sp.edit().putString("ai_config", meta.toString()).apply()
        }
    }

    // ---- 设备列表（pull 的 userdb 条目带 device_id） ----

    fun devices(): MutableSet<String> =
        (sp.getStringSet("devices", emptySet()) ?: emptySet()).toMutableSet()

    fun addDevice(id: String) {
        if (id.isEmpty()) return
        val s = devices()
        if (s.add(id)) sp.edit().putStringSet("devices", s).apply()
    }

    // ---- 一键学习重置 / 清空 ----

    fun resetLearning() {
        sp.edit().remove("userdb").remove("pending_counters").remove("server_counters").apply()
    }

    fun clearAll() {
        sp.edit().clear().apply()
    }

    private fun json(s: String): JSONObject =
        try {
            JSONObject(s)
        } catch (_: Exception) {
            JSONObject()
        }
}
