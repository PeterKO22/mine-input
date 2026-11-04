package com.mineinput.ime.sync

import android.content.Context
import android.util.Log
import com.mineinput.ime.Prefs
import org.json.JSONObject

/**
 * W11 同步编排：知情同意门控（FR8）+ push/pull 往返 + 离线队列静默补传。
 *
 * 门控（撤回即停，不上报）：
 *   - 一键熔断（fuse）→ 一切采集与上报停止；
 *   - 无任一同意项 → 不上报（push/ingest 全拒）；
 *   - userdb/计数器/meta 上行需 C0；热词上行/合并需 热词同步 同意；
 *   - ocr_digest/asr_digest（高敏，C2）字段仅在 C2 同意时随事件携带。
 */
object SyncManager {

    const val TAG = "W11"

    private lateinit var app: Context
    private lateinit var consent: Prefs.Consent
    private lateinit var pairing: Prefs.Pairing
    private lateinit var settings: Prefs.SettingsStore
    lateinit var store: SyncStore
        private set
    lateinit var queue: OfflineQueue
        private set

    fun init(ctx: Context) {
        if (::app.isInitialized) return
        app = ctx.applicationContext
        consent = Prefs.Consent(app)
        pairing = Prefs.Pairing(app)
        settings = Prefs.SettingsStore(app)
        store = SyncStore(app)
        queue = OfflineQueue(app)
    }

    private fun api() = HubApi(pairing.baseUrl, pairing.token)

    // ---- W24：密码框隐私（Mac C1 设计同步）——焦点进入密码框 → 一切采集/上报暂停 ----

    @Volatile
    var collectionPaused = false

    @Volatile
    var collectionPauseReason = ""

    // ---- 门控 ----

    fun fuseBlown(): Boolean = settings.fuseBlown

    /** 可以上报（push/ingest）：未熔断 + 已配对 + 至少一项同意。 */
    fun canUpload(): Boolean =
        !settings.fuseBlown && pairing.paired && consent.any

    fun blockReason(): String = when {
        settings.fuseBlown -> "fuse"
        !pairing.paired -> "not-paired"
        !consent.any -> "no-consent"
        else -> ""
    }

    // ---- 事件上报（MineImeService 候选/PTT 真实事件与调试事件同路） ----

    /** 交互事件入队（静默），随后尝试补传。同意撤回/熔断 → 直接拒收（不再上报）。 */
    fun recordInteraction(ev: JSONObject): String {
        if (collectionPaused) {
            // W24：密码框等隐私焦点 → 采集闸关死（含 voice_session/candidate_pick 一切事件）
            Log.i("W24", "COLLECT_BLOCKED|reason=$collectionPauseReason|kind=${ev.optString("kind")}")
            return "blocked:$collectionPauseReason"
        }
        if (!canUpload() || !consent.c0) {
            val reason = if (blockReason().isNotEmpty()) blockReason() else "no-c0-consent"
            Log.i(TAG, "UPLOAD_BLOCKED kind=${ev.optString("kind")} reason=$reason")
            return "blocked:$reason"
        }
        if (!consent.c2) {
            ev.remove("ocr_digest")
            ev.remove("asr_digest") // 高敏字段仅 C2 同意时携带
        }
        queue.enqueueIngest(ev)
        Log.i(TAG, "INGEST_ENQUEUED depth=${queue.depth()} kind=${ev.optString("kind")}")
        flushSilent()
        return "queued"
    }

    /** 静默补传：失败留队，不做用户可见报错（W8 失败静默重试语义）。 */
    fun flushSilent(): OfflineQueue.FlushResult {
        val res = queue.flush(api())
        if (res.sent > 0 || res.kept > 0 || res.dropped > 0) {
            Log.i(TAG, "QUEUE_FLUSH sent=${res.sent} kept=${res.kept} dropped=${res.dropped} err=${res.error}")
        }
        return res
    }

    // ---- push / pull ----

    data class SyncReport(
        val blocked: Boolean,
        val blockReason: String,
        val pushStatus: String = "",
        val pushDuplicate: Boolean = false,
        val pushId: String = "",
        val pullOk: Boolean = false,
        val roundtrip: Boolean = false,
        val roundtripDetail: String = "",
        val queueDepth: Int = 0,
        val flushSent: Int = 0,
        val flushKept: Int = 0,
    )

    /** 立即同步：组 push（按同意分项）→ 入队 → 补传 → pull → 本地合并 → 往返校验。 */
    fun syncNow(reason: String): SyncReport {
        if (!canUpload()) {
            val r = blockReason()
            Log.i(TAG, "SYNC_BLOCKED reason=$r")
            return SyncReport(blocked = true, blockReason = r, queueDepth = queue.depth())
        }
        serverSnapshotBefore = store.serverCounters() // 往返校验基线：同步前服务器累计

        // ---- 组 push（快照固化进队列，push_id 随条目持久化 → 重试幂等） ----
        val sentUserdb = mutableListOf<UserdbEntry>()
        val sentCounters = JSONObject()
        val sentHotwords = mutableListOf<String>()
        val body = JSONObject()
            .put("device_id", pairing.deviceId)
            .put("push_id", HubApi.makePushId())
            .put("userdb", org.json.JSONArray())
            .put("counters", JSONObject())
            .put("hotwords", org.json.JSONArray())

        if (consent.c0) {
            val u = store.userdb()
            for (k in u.keys()) {
                val e = u.optJSONObject(k) ?: continue
                val entry = UserdbEntry(k, e.optString("value"), e.optLong("updated_at"))
                sentUserdb.add(entry)
                body.getJSONArray("userdb").put(
                    JSONObject().put("key", entry.key).put("value", entry.value).put("updated_at", entry.updatedAt)
                )
            }
            val pending = store.pendingCounters()
            for (k in pending.keys()) {
                val v = pending.optLong(k)
                sentCounters.put(k, v)
                body.getJSONObject("counters").put(k, v)
            }
            body.put(
                "schema_version",
                JSONObject().put("updated_at", System.currentTimeMillis()).put("value", "ping_wubi_mixed@1")
            )
        }
        if (consent.hotword) {
            sentHotwords.addAll(store.hotwords())
            for (h in sentHotwords) body.getJSONArray("hotwords").put(h)
        }

        val hasPayload = sentUserdb.isNotEmpty() || sentCounters.length() > 0 || sentHotwords.isNotEmpty()
        val pushId = body.getString("push_id")
        if (hasPayload) queue.enqueuePush(body, pushId)

        // ---- 补传（含新入队条目） ----
        val flush = flushSilent()

        // push 成功扣除增量（duplicate 亦扣：服务端已计入）
        if (flush.sent > 0 && consent.c0 && sentCounters.length() > 0) {
            store.ackCounters(sentCounters)
        }

        // ---- pull 合并态 ----
        var pullOk = false
        var roundtrip = false
        var detail = ""
        when (val r = api().pull(pairing.deviceId, null)) {
            is ApiResult.Ok -> {
                pullOk = true
                val st = r.value
                store.mergeUserdb(st.userdb)
                store.setServerCounters(st.counters)
                if (consent.hotword) store.mergeHotwords(st.hotwords)
                store.mergeSchemaVersion(st.schemaVersion)
                store.mergeAiConfig(st.aiConfig)
                store.addDevice(pairing.deviceId)
                for (e in st.userdb) store.addDevice(e.deviceId)

                // ---- push→pull 往返一致校验 ----
                val problems = mutableListOf<String>()
                val pulled = st.userdb.associateBy { it.key }
                for (e in sentUserdb) {
                    val p = pulled[e.key]
                    if (p == null) problems.add("userdb:${e.key}=missing")
                    else if (p.value != e.value) problems.add("userdb:${e.key}=${p.value}!=${e.value}")
                }
                for (k in sentCounters.keys()) {
                    // 计数器增量累加：服务端累计应 = 同步前累计 + 本次增量
                    val now = st.counters[k] ?: 0L
                    val delta = sentCounters.optLong(k)
                    if (serverSnapshotBefore.has(k)) {
                        val expect = serverSnapshotBefore.optLong(k) + delta
                        if (now != expect) problems.add("counters:$k=$now!=$expect")
                    } else {
                        // 无本地基线（重装/清数据后同账号再同步）：仅验下界防丢增量；
                        // 严格相等不可判（服务端可能已有历史累计或多设备叠加），防假阴性
                        if (now < delta) problems.add("counters:$k=$now<$delta")
                    }
                }
                if (consent.hotword) {
                    for (h in sentHotwords) {
                        if (!st.hotwords.contains(h)) problems.add("hotword:$h=missing")
                    }
                }
                roundtrip = problems.isEmpty()
                detail = if (roundtrip) {
                    val u = sentUserdb.joinToString(",") { "${it.key}=${it.value}" }
                    "userdb[$u] counters=${sentCounters} hotwords=$sentHotwords"
                } else {
                    problems.joinToString("; ")
                }
            }
            is ApiResult.Err -> detail = "pull ${r.kind}: http=${r.httpCode} ${r.message}"
        }

        settings.lastSyncAt = System.currentTimeMillis()
        val report = SyncReport(
            blocked = false,
            blockReason = "",
            pushStatus = if (hasPayload) "sent" else "empty",
            pushDuplicate = false,
            pushId = if (hasPayload) pushId else "",
            pullOk = pullOk,
            roundtrip = roundtrip,
            roundtripDetail = detail,
            queueDepth = queue.depth(),
            flushSent = flush.sent,
            flushKept = flush.kept,
        )
        Log.i(
            TAG,
            "SYNC reason=$reason push=${report.pushStatus} push_id=${report.pushId} " +
                "flush_sent=${report.flushSent} flush_kept=${report.flushKept} pull=$pullOk " +
                "roundtrip=$roundtrip detail=$detail queue=${report.queueDepth}"
        )
        return report
    }

    /** syncNow 前的服务器计数器快照（往返校验基线）。 */
    private var serverSnapshotBefore = JSONObject()

    fun syncNowAndLog(reason: String): SyncReport {
        val r = syncNow(reason)
        Log.i(
            TAG,
            if (r.blocked) "ROUNDTRIP_SKIP reason=${r.blockReason}"
            else if (r.roundtrip) "ROUNDTRIP_OK ${r.roundtripDetail}"
            else "ROUNDTRIP_FAIL ${r.roundtripDetail}"
        )
        return r
    }

    // ---- 配对（真连） ----

    /**
     * 配对码真连：`用户名:密码` 直连凭据，或配对码派生确定性凭据（同码=同账号）。
     * 流程：register（409=已存在忽略）→ token → whoami 校验 → 落盘。
     */
    fun pair(inputCode: String): String {
        val creds = Prefs.credentialsFromPairingCode(inputCode)
            ?: return "PAIR_FAIL bad-code"
        val (username, password) = creds
        val api = HubApi(pairing.baseUrl, null)
        when (val reg = api.register(username, password)) {
            is ApiResult.Ok -> Log.i(TAG, "PAIR_REGISTER user_id=${reg.value.optLong("user_id")} kp=${reg.value.optJSONObject("key_partition")?.optString("id")}")
            is ApiResult.Err -> {
                if (reg.httpCode != 409) {
                    Log.i(TAG, "PAIR_FAIL register ${reg.kind} http=${reg.httpCode} ${reg.message}")
                    return "PAIR_FAIL register ${reg.kind} http=${reg.httpCode}"
                }
            }
        }
        val login = api.login(username, password)
        if (login !is ApiResult.Ok) {
            val e = login as ApiResult.Err
            Log.i(TAG, "PAIR_FAIL login ${e.kind} http=${e.httpCode} ${e.message}")
            return "PAIR_FAIL login ${e.kind} http=${e.httpCode}"
        }
        val token = login.value.optString("access_token")
        val userId = login.value.optLong("user_id")
        val kpId = login.value.optString("key_partition_id")
        val api2 = HubApi(pairing.baseUrl, token)
        val who = api2.whoami()
        if (who !is ApiResult.Ok) {
            Log.i(TAG, "PAIR_FAIL whoami")
            return "PAIR_FAIL whoami"
        }
        pairing.username = username
        pairing.token = token
        pairing.userId = userId
        pairing.keyPartitionId = kpId
        pairing.pairedAt = System.currentTimeMillis()
        store.addDevice(pairing.deviceId)
        Log.i(
            TAG,
            "PAIR_OK hub=${pairing.baseUrl} user_id=$userId key_partition=$kpId device=${pairing.deviceId}"
        )
        return "PAIR_OK user_id=$userId key_partition=$kpId"
    }
}
