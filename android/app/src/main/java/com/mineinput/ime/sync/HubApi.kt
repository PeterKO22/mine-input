package com.mineinput.ime.sync

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

/**
 * W11 同步客户端 —— Kotlin 直接 HTTP，字段以 hub/app/main.py（W4 实现）为准，
 * 语义对齐 sdk/W8-REPORT.md：
 *   auth  : /v1/auth/register · /v1/auth/token · /v1/auth/whoami
 *   push  : userdb 时间戳取新 / 计数器增量累加 / 热词集合并 / meta 取新，
 *           push_id 幂等（重发返回 duplicate:true 且不重复累加）
 *   pull  : 合并态（since 可选增量），返回 userdb(含 device_id)/counters(累计)/hotwords/meta
 *   ingest: InteractionEvent 上行（kind 枚举同 hub 校验）
 *
 * 错误语义（W8 同款）：Network / Timeout / Auth(401) / 408 / 429 / 5xx → retryable；
 * 其余 4xx 与解析错误 → 永久错误（不重试，离线队列丢弃防死循环）。
 */
sealed class ApiResult<out T> {
    data class Ok<T>(val value: T) : ApiResult<T>()
    data class Err(
        val httpCode: Int,
        val kind: String, // network | timeout | auth | http | parse
        val message: String,
        val retryable: Boolean,
    ) : ApiResult<Nothing>()
}

data class UserdbEntry(
    val key: String,
    val value: String,
    val updatedAt: Long,
    val deviceId: String = "",
)

data class PushPayload(
    val deviceId: String,
    val pushId: String,
    val userdb: List<UserdbEntry> = emptyList(),
    val counters: Map<String, Long> = emptyMap(),
    val hotwords: List<String> = emptyList(),
    val aiConfig: JSONObject? = null,      // {"updated_at": ms, "value": {...}}
    val schemaVersion: JSONObject? = null, // {"updated_at": ms, "value": "..."}
)

data class PushResult(
    val status: String,
    val pushId: String,
    val duplicate: Boolean,
    val applied: JSONObject,
)

data class PullState(
    val serverTime: Long,
    val userdb: List<UserdbEntry>,
    val counters: Map<String, Long>,
    val hotwords: List<String>,
    val aiConfig: JSONObject?,
    val schemaVersion: JSONObject?,
)

class HubApi(var baseUrl: String, var token: String?) {

    companion object {
        // sync/ingest 为后台通道（W8：默认 8s；suggest 的 800ms 预算属面向用户通道，W11 未接 suggest）
        const val CONNECT_TIMEOUT_MS = 8000
        const val READ_TIMEOUT_MS = 8000

        init {
            // 禁 JVM 级 keep-alive 池（同 Connection: close）
            System.setProperty("http.keepAlive", "false")
        }

        fun makePushId(): String =
            "w11-" + java.util.UUID.randomUUID().toString().replace("-", "").take(16)
    }

    // ---- auth ----

    fun register(username: String, password: String): ApiResult<JSONObject> =
        call("POST", "/v1/auth/register", JSONObject().put("username", username).put("password", password), null)

    fun login(username: String, password: String): ApiResult<JSONObject> =
        call("POST", "/v1/auth/token", JSONObject().put("username", username).put("password", password), null)

    fun whoami(): ApiResult<JSONObject> = call("GET", "/v1/auth/whoami", null, token)

    // ---- sync ----

    fun push(p: PushPayload): ApiResult<PushResult> = pushRaw(pushBody(p))

    /** 离线队列补传用：直接投递已固化的请求体（push_id 原样沿用 → 幂等重试）。 */
    fun pushRaw(body: JSONObject): ApiResult<PushResult> =
        when (val r = call("POST", "/v1/sync/push", body, token)) {
            is ApiResult.Ok -> ApiResult.Ok(
                PushResult(
                    status = r.value.optString("status"),
                    pushId = r.value.optString("push_id"),
                    duplicate = r.value.optBoolean("duplicate"),
                    applied = r.value.optJSONObject("applied") ?: JSONObject(),
                )
            )
            is ApiResult.Err -> r
        }

    fun pushBody(p: PushPayload): JSONObject {
        val userdb = JSONArray()
        for (e in p.userdb) {
            userdb.put(JSONObject().put("key", e.key).put("value", e.value).put("updated_at", e.updatedAt))
        }
        val counters = JSONObject()
        for ((k, v) in p.counters) counters.put(k, v)
        val hotwords = JSONArray()
        for (h in p.hotwords) hotwords.put(h)
        val body = JSONObject()
            .put("device_id", p.deviceId)
            .put("push_id", p.pushId)
            .put("userdb", userdb)
            .put("counters", counters)
            .put("hotwords", hotwords)
        if (p.aiConfig != null) body.put("ai_config", p.aiConfig)
        if (p.schemaVersion != null) body.put("schema_version", p.schemaVersion)
        return body
    }

    fun pull(deviceId: String, since: Long?): ApiResult<PullState> {
        val body = JSONObject().put("device_id", deviceId)
        if (since != null) body.put("since", since)
        return when (val r = call("POST", "/v1/sync/pull", body, token)) {
            is ApiResult.Ok -> {
                val v = r.value
                val userdb = mutableListOf<UserdbEntry>()
                val arr = v.optJSONArray("userdb") ?: JSONArray()
                for (i in 0 until arr.length()) {
                    val e = arr.optJSONObject(i) ?: continue
                    userdb.add(
                        UserdbEntry(
                            key = e.optString("key"),
                            value = e.optString("value"),
                            updatedAt = e.optLong("updated_at"),
                            deviceId = e.optString("device_id"),
                        )
                    )
                }
                val counters = mutableMapOf<String, Long>()
                val cObj = v.optJSONObject("counters") ?: JSONObject()
                for (k in cObj.keys()) counters[k] = cObj.optLong(k)
                val hotwords = mutableListOf<String>()
                val hArr = v.optJSONArray("hotwords") ?: JSONArray()
                for (i in 0 until hArr.length()) hotwords.add(hArr.optString(i))
                ApiResult.Ok(
                    PullState(
                        serverTime = v.optLong("server_time"),
                        userdb = userdb,
                        counters = counters,
                        hotwords = hotwords,
                        aiConfig = v.optJSONObject("ai_config"),
                        schemaVersion = v.optJSONObject("schema_version"),
                    )
                )
            }
            is ApiResult.Err -> r
        }
    }

    // ---- ingest（InteractionEvent，字段对齐 hub IngestIn）----

    // 不做请求级重试：/v1/ingest 服务端无幂等（W8 已知边界），重试统一走离线队列语义
    fun ingest(event: JSONObject): ApiResult<JSONObject> =
        call("POST", "/v1/ingest", event, token, retryOnTransient = false)

    // ---- HTTP 层 ----

    private fun call(
        method: String,
        path: String,
        body: JSONObject?,
        bearer: String?,
        retryOnTransient: Boolean = true,
    ): ApiResult<JSONObject> {
        var attempt = 0
        while (true) {
            val r = doCall(method, path, body, bearer)
            // 瞬时错误（network/timeout）静默重试一次（W8 失败静默重试语义）
            if (r is ApiResult.Err && retryOnTransient && attempt == 0 &&
                (r.kind == "network" || r.kind == "timeout")
            ) {
                attempt++
                continue
            }
            return r
        }
    }

    private fun doCall(method: String, path: String, body: JSONObject?, bearer: String?): ApiResult<JSONObject> {
        return try {
            val conn = (URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                doInput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Connection", "close") // 禁连接复用：模拟器 NAT 下 keep-alive 复用易挂死（W11 实测）
                if (bearer != null) setRequestProperty("Authorization", "Bearer $bearer")
                if (body != null) {
                    doOutput = true
                    outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            conn.disconnect()
            if (code in 200..299) {
                try {
                    ApiResult.Ok(if (text.isBlank()) JSONObject() else JSONObject(text))
                } catch (e: Exception) {
                    ApiResult.Err(code, "parse", "bad json: ${e.message}", false)
                }
            } else {
                val retryable = code == 401 || code == 408 || code == 429 || code >= 500
                ApiResult.Err(code, if (code == 401) "auth" else "http", text.take(200), retryable)
            }
        } catch (e: SocketTimeoutException) {
            ApiResult.Err(-1, "timeout", e.message ?: "timeout", true)
        } catch (e: IOException) {
            ApiResult.Err(-1, "network", e.message ?: "io error", true)
        } catch (e: Exception) {
            ApiResult.Err(-1, "error", e.message ?: "error", false)
        }
    }
}
