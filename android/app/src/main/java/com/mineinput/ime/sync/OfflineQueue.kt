package com.mineinput.ime.sync

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

/**
 * W11 离线队列 —— 文件队列（框架 SQLite，非 Room，零第三方依赖）。
 * 语义对齐 sdk/W8-REPORT OfflineQueue：
 *   断网入队（push/ingest）→ 联网 FIFO 补传 → 失败静默重试（attempts 留痕）；
 *   push 条目持久化原始请求体（含原 push_id）→ 补传保持幂等；
 *   可重试错误留队即停（保序），永久 4xx 丢弃防死循环。
 */
class OfflineQueue(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "w11-offline-queue.db", null, 1) {

    data class Entry(
        val id: Long,
        val kind: String,
        val payload: String,
        val pushId: String?,
        val attempts: Int,
    )

    data class FlushResult(
        var sent: Int = 0,
        var kept: Int = 0,
        var dropped: Int = 0,
        var error: String = "",
    )

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE queue (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT," +
                "kind TEXT NOT NULL," +
                "payload TEXT NOT NULL," +
                "push_id TEXT," +
                "attempts INTEGER NOT NULL DEFAULT 0," +
                "created_at INTEGER NOT NULL)"
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    fun enqueuePush(body: JSONObject, pushId: String) = enqueue("push", body, pushId)

    fun enqueueIngest(event: JSONObject) = enqueue("ingest", event, null)

    private fun enqueue(kind: String, payload: JSONObject, pushId: String?) {
        val cv = ContentValues().apply {
            put("kind", kind)
            put("payload", payload.toString())
            put("push_id", pushId)
            put("attempts", 0)
            put("created_at", System.currentTimeMillis())
        }
        writableDatabase.insert("queue", null, cv)
    }

    fun depth(): Int =
        readableDatabase.rawQuery("SELECT COUNT(*) FROM queue", null).use {
            it.moveToFirst()
            it.getInt(0)
        }

    fun clear(): Int = writableDatabase.delete("queue", null, null)

    /** FIFO 补传。成功（含 duplicate）→ 删除；可重试失败 → attempts++ 并停（保序）；永久错误 → 丢弃。 */
    fun flush(api: HubApi): FlushResult {
        val res = FlushResult()
        while (true) {
            val e = next() ?: break
            val payload = try {
                JSONObject(e.payload)
            } catch (_: Exception) {
                delete(e.id)
                res.dropped++
                continue
            }
            val r = when (e.kind) {
                "push" -> api.pushRaw(payload)
                else -> api.ingest(payload)
            }
            when (r) {
                is ApiResult.Ok -> {
                    delete(e.id)
                    res.sent++
                }
                is ApiResult.Err -> {
                    if (r.retryable) {
                        bump(e.id)
                        res.kept++
                        res.error = "${r.kind}: http=${r.httpCode} ${r.message}"
                        break // 保序：头部失败即停，不绕过
                    } else {
                        delete(e.id)
                        res.dropped++
                    }
                }
            }
        }
        return res
    }

    private fun next(): Entry? =
        readableDatabase.rawQuery(
            "SELECT id, kind, payload, push_id, attempts FROM queue ORDER BY id LIMIT 1",
            null
        ).use {
            if (!it.moveToFirst()) return null
            Entry(it.getLong(0), it.getString(1), it.getString(2), it.getString(3), it.getInt(4))
        }

    private fun delete(id: Long) {
        writableDatabase.delete("queue", "id=?", arrayOf(id.toString()))
    }

    private fun bump(id: Long) {
        writableDatabase.execSQL("UPDATE queue SET attempts = attempts + 1 WHERE id=?", arrayOf(id))
    }
}
