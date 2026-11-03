package com.mineinput.ime

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.mineinput.ime.sync.SyncManager
import org.json.JSONObject
import java.io.File

/**
 * W11 设置分区详情页（A4 → M4–M7 各分区内容）：
 * 通用 / 输入方案 / 自适应学习 / 采集与上下文（含一键熔断）/
 * AI 与同步（连接状态 · 立即同步 · 设备列表）/ 隐私与数据（导出 · 清空 · 同意撤回）/ 关于。
 */
class SectionActivity : Activity() {

    companion object {
        const val EXTRA_SECTION = "section"
        const val SECTION_GENERAL = "general"
        const val SECTION_SCHEMA = "schema"
        const val SECTION_LEARN = "learn"
        const val SECTION_COLLECT = "collect"
        const val SECTION_AI = "ai_sync"
        const val SECTION_PRIVACY = "privacy"
        const val SECTION_ABOUT = "about"
    }

    private lateinit var consent: Prefs.Consent
    private lateinit var pairing: Prefs.Pairing
    private lateinit var settings: Prefs.SettingsStore
    private var statusLine: TextView? = null
    private var root: LinearLayout? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consent = Prefs.Consent(this)
        pairing = Prefs.Pairing(this)
        settings = Prefs.SettingsStore(this)
        SyncManager.init(this)

        val pad = Ui.dp(this, 16f)
        val scroll = ScrollView(this).apply {
            setBackgroundColor(DesignTokens.bg)
            isFillViewport = true
        }
        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad * 2)
        }
        root = rootLayout

        // 返回行
        rootLayout.addView(
            Ui.button(this, "‹ 返回设置", Ui.Style.SECONDARY) { finish() }
        )

        when (intent.getStringExtra(EXTRA_SECTION) ?: SECTION_GENERAL) {
            SECTION_GENERAL -> buildGeneral(rootLayout)
            SECTION_SCHEMA -> buildSchema(rootLayout)
            SECTION_LEARN -> buildLearn(rootLayout)
            SECTION_COLLECT -> buildCollect(rootLayout)
            SECTION_AI -> buildAi(rootLayout)
            SECTION_PRIVACY -> buildPrivacy(rootLayout)
            SECTION_ABOUT -> buildAbout(rootLayout)
        }

        statusLine = Ui.muted(this, "")
        rootLayout.addView(statusLine as TextView)
        scroll.addView(rootLayout)
        setContentView(scroll)
    }

    private fun status(msg: String, ok: Boolean = true) {
        statusLine?.text = msg
        statusLine?.setTextColor(if (ok) DesignTokens.green else DesignTokens.red)
    }

    // ---------------------------------------------------------------- 通用

    private fun buildGeneral(root: LinearLayout) {
        root.addView(Ui.heading(this, "通用"))
        root.addView(
            Ui.toggleRow(this, "按键音", "系统按键音效", settings.keySound) { settings.keySound = it }
        )
        root.addView(
            Ui.toggleRow(this, "按键振动", "轻触振动反馈", settings.keyVibrate) { settings.keyVibrate = it }
        )
        root.addView(
            Ui.toggleRow(this, "性能模式", "低端机型关闭发光效果（design-language §6）", settings.perfMode) {
                settings.perfMode = it
            }
        )
        root.addView(Ui.divider(this))
        root.addView(Ui.muted(this, "键位排布遵循平台习惯，仅换肤不改形（A1 映射）"))
    }

    // ---------------------------------------------------------------- 输入方案

    private fun buildSchema(root: LinearLayout) {
        root.addView(Ui.heading(this, "输入方案"))
        val info = Ui.column(this)
        info.addView(Ui.body(this, "当前方案"))
        info.addView(Ui.mono(this, "ping_wubi_mixed@1  五笔86+拼音", DesignTokens.gold))
        info.addView(Ui.muted(this, "形码优先 · 拼音并联兜底 · 拼音反查（FR1）"))
        root.addView(Ui.card(this, info))
        root.addView(
            Ui.toggleRow(this, "空码顶字", "FR1 默认关：空格不顶首选", settings.emptyCodeCommit) {
                settings.emptyCodeCommit = it
            }
        )
        root.addView(Ui.divider(this))
        root.addView(Ui.mono(this, "schema_version 随同步取新（W8 meta 语义）", DesignTokens.textMuted))
    }

    // ---------------------------------------------------------------- 自适应学习

    private fun buildLearn(root: LinearLayout) {
        root.addView(Ui.heading(this, "自适应学习"))
        root.addView(
            Ui.toggleRow(this, "L1 用户词典", "自造词与词形学习（本地）", settings.learnL1) {
                settings.learnL1 = it
            }
        )
        root.addView(
            Ui.toggleRow(this, "L2 词频/习惯", "使用习惯计数，随同步增量累加（需 C0 同意才上报）", settings.learnL2) {
                settings.learnL2 = it
            }
        )
        root.addView(Ui.divider(this))
        val u = SyncManager.store.userdb()
        val counters = SyncManager.store.pendingCounters()
        val server = SyncManager.store.serverCounters()
        val info = Ui.column(this)
        info.addView(Ui.body(this, "本地学习状态"))
        info.addView(Ui.mono(this, "userdb 条目 ${u.length()} · 待发计数 ${counters.length()} · 服务端累计 ${server.length()}", DesignTokens.gold))
        root.addView(Ui.card(this, info))
        root.addView(
            Ui.button(this, "一键学习重置", Ui.Style.DANGER) {
                SyncManager.store.resetLearning()
                status("✓ 学习数据已重置")
            }
        )
        root.addView(Ui.muted(this, "NFR8：一键导出 / 一键清空 / 一键学习重置全可用"))
    }

    // ---------------------------------------------------------------- 采集与上下文

    private fun buildCollect(root: LinearLayout) {
        root.addView(Ui.heading(this, "采集与上下文"))

        val statusCard = Ui.column(this)
        statusCard.addView(Ui.body(this, "采集状态（常显）"))
        val chips = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        chips.addView(Ui.chip(this, "C0 ${if (consent.c0) "已同意" else "未同意"}", if (consent.c0) DesignTokens.cyan else DesignTokens.textMuted))
        val lp1 = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp1.leftMargin = Ui.dp(this, 6f)
        (chips.getChildAt(chips.childCount - 1) as TextView).layoutParams = lp1
        chips.addView(Ui.chip(this, "C2 ${if (consent.c2) "已同意" else "未同意"}", if (consent.c2) DesignTokens.red else DesignTokens.textMuted))
        val lp2 = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp2.leftMargin = Ui.dp(this, 6f)
        (chips.getChildAt(chips.childCount - 1) as TextView).layoutParams = lp2
        if (SyncManager.fuseBlown()) {
            chips.addView(Ui.chip(this, "熔断中", DesignTokens.red))
            val lp3 = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp3.leftMargin = Ui.dp(this, 6f)
            (chips.getChildAt(chips.childCount - 1) as TextView).layoutParams = lp3
        }
        statusCard.addView(chips)
        root.addView(Ui.card(this, statusCard))

        root.addView(
            Ui.toggleRow(this, "C0 基础上下文", "按键会话/候选选择（联动同意清单）", consent.c0) {
                consent.c0 = it; consent.touch()
            }
        )
        root.addView(
            Ui.toggleRow(this, "C2 读屏上下文", "高敏 · Android 上限：需开无障碍服务（未开则采集项如实标注为关）", consent.c2) {
                consent.c2 = it; consent.touch()
            }
        )
        root.addView(
            Ui.toggleRow(this, "语音热词同步", "热词表设备 ⇄ Hub 同步", consent.hotword) {
                consent.hotword = it; consent.touch()
            }
        )
        root.addView(Ui.divider(this))
        root.addView(
            Ui.button(this, "一键熔断", Ui.Style.DANGER) {
                settings.fuseBlown = true
                status("● 熔断已触发：一切采集与上报立即停止", false)
            }
        )
        root.addView(
            Ui.button(this, "恢复采集（解除熔断）", Ui.Style.SECONDARY) {
                settings.fuseBlown = false
                status("✓ 熔断已解除")
            }
        )
        root.addView(Ui.muted(this, "FR8：一键熔断 + 采集状态常显（菜单/状态条变色）"))
    }

    // ---------------------------------------------------------------- AI 与同步

    private fun buildAi(root: LinearLayout) {
        root.addView(Ui.heading(this, "AI 与同步"))

        // 连接状态
        val conn = Ui.column(this)
        conn.addView(Ui.body(this, "连接状态"))
        val connected = pairing.paired
        conn.addView(
            Ui.chip(
                this,
                if (connected) "本地 Hub · 已连接" else "本地 Hub · 未连接",
                if (connected) DesignTokens.green else DesignTokens.textMuted
            )
        )
        conn.addView(Ui.mono(this, pairing.baseUrl, DesignTokens.gold))
        conn.addView(Ui.mono(this, "user=${pairing.username.ifEmpty { "-" }} · device=${pairing.deviceId}", DesignTokens.textMuted))
        conn.addView(Ui.mono(this, "key_partition=${pairing.keyPartitionId.ifEmpty { "-" }}", DesignTokens.textMuted))
        root.addView(Ui.card(this, conn))

        // 立即同步
        root.addView(
            Ui.button(this, "立即同步", Ui.Style.PRIMARY) {
                status("同步中…")
                Thread {
                    val r = SyncManager.syncNowAndLog("settings-ui")
                    runOnUiThread {
                        status(
                            if (r.blocked) "✗ 同步被拦截：${r.blockReason}"
                            else if (r.roundtrip) "✓ push→pull 往返一致 · ${r.roundtripDetail}"
                            else "✗ 往返校验失败：${r.roundtripDetail}",
                            ok = !r.blocked && r.roundtrip
                        )
                    }
                }.start()
            }
        )
        root.addView(
            Ui.button(this, "测试连接", Ui.Style.SECONDARY) {
                Thread {
                    val ok = try {
                        java.net.URL(pairing.baseUrl.trimEnd('/') + "/healthz").openConnection()
                            .let { it as java.net.HttpURLConnection }
                            .let { c -> c.connectTimeout = 4000; c.readTimeout = 4000; c.responseCode == 200 }
                    } catch (e: Exception) {
                        false
                    }
                    runOnUiThread {
                        status(if (ok) "✓ Hub 可达 ${pairing.baseUrl}" else "✗ Hub 不可达 ${pairing.baseUrl}", ok)
                    }
                }.start()
            }
        )

        // 队列与最近同步
        val q = Ui.column(this)
        q.addView(Ui.body(this, "同步通道"))
        q.addView(Ui.mono(this, "离线队列 ${SyncManager.queue.depth()} 条（失败静默重试 · push_id 幂等）", DesignTokens.gold))
        val last = settings.lastSyncAt
        q.addView(Ui.mono(this, if (last > 0) "上次同步 ${java.text.SimpleDateFormat("HH:mm:ss").format(java.util.Date(last))}" else "尚未同步", DesignTokens.textMuted))
        root.addView(Ui.card(this, q))

        // 设备列表
        val dev = Ui.column(this)
        dev.addView(Ui.body(this, "设备列表"))
        val devices = SyncManager.store.devices().sorted()
        if (devices.isEmpty()) {
            dev.addView(Ui.mono(this, "（仅本机 · 同步后展示其他设备）", DesignTokens.textMuted))
        } else {
            for (d in devices) {
                dev.addView(Ui.mono(this, (if (d == pairing.deviceId) "● " else "○ ") + d, if (d == pairing.deviceId) DesignTokens.gold else DesignTokens.textBody))
            }
        }
        root.addView(Ui.card(this, dev))
        root.addView(Ui.muted(this, "合并语义：userdb 取新 · 计数器增量累加 · 热词集合并（W8 对齐）"))
    }

    // ---------------------------------------------------------------- 隐私与数据

    private fun buildPrivacy(root: LinearLayout) {
        root.addView(Ui.heading(this, "隐私与数据"))

        val c = Ui.column(this)
        c.addView(Ui.body(this, "同意清单（随时可撤回）"))
        c.addView(Ui.mono(this, "同意时间 ${if (consent.consentedAt > 0) java.text.SimpleDateFormat("yyyy-MM-dd HH:mm").format(java.util.Date(consent.consentedAt)) else "-"}", DesignTokens.textMuted))
        root.addView(Ui.card(this, c))

        root.addView(Ui.toggleRow(this, "C0 基础上下文", "撤回后基础上下文不再上报", consent.c0) { consent.c0 = it; consent.touch() })
        root.addView(Ui.toggleRow(this, "C2 读屏上下文", "撤回后高敏字段不再上报", consent.c2) { consent.c2 = it; consent.touch() })
        root.addView(Ui.toggleRow(this, "语音热词同步", "撤回后热词不再同步", consent.hotword) { consent.hotword = it; consent.touch() })

        root.addView(Ui.divider(this))
        root.addView(
            Ui.button(this, "撤回全部同意", Ui.Style.DANGER) {
                consent.withdrawAll()
                SyncManager.queue.clear() // 未上报的排队数据一并作废（不再上报）
                status("✓ 已撤回全部同意 · 上报通道关闭（本地数据保留，可一键清空）", false)
            }
        )
        root.addView(
            Ui.button(this, "导出数据", Ui.Style.SECONDARY) {
                try {
                    val json = Prefs.exportJson(this, consent, pairing, SyncManager.store, SyncManager.queue.depth())
                    val dir = getExternalFilesDir(null) ?: filesDir
                    val f = File(dir, "mine-input-export-${System.currentTimeMillis()}.json")
                    f.writeText(json.toString(2))
                    status("✓ 已导出：${f.absolutePath}")
                } catch (e: Exception) {
                    status("✗ 导出失败：${e.message}", false)
                }
            }
        )
        root.addView(
            Ui.button(this, "清空本地数据", Ui.Style.DANGER) {
                SyncManager.store.clearAll()
                SyncManager.queue.clear()
                status("✓ 本地学习/队列数据已清空（同意与配对保留）")
            }
        )
        root.addView(Ui.muted(this, "FR8：数据只存于「你的设备 + 你的 Hub」，不经过任何第三方云"))
    }

    // ---------------------------------------------------------------- 关于

    private fun buildAbout(root: LinearLayout) {
        root.addView(Ui.heading(this, "关于"))
        val c = Ui.column(this)
        c.addView(Ui.body(this, "mine-input Android"))
        c.addView(Ui.mono(this, "versionName 0.2.0-w11 · minSdk 29 · Kotlin IMS 骨架", DesignTokens.gold))
        c.addView(Ui.muted(this, "视觉唯一风格源：design/design-language.md（深色科幻 + HUD）"))
        c.addView(Ui.muted(this, "同步语义：sdk/W8（push_id 幂等 · 离线队列 · 静默重试）"))
        c.addView(Ui.muted(this, "许可证：当前无第三方代码；接入 librime/Trime 内核须转 GPLv3（W5 结论留档）"))
        root.addView(Ui.card(this, c))
    }
}
