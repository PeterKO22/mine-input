package com.mineinput.ime

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.mineinput.ime.sync.SyncManager

/**
 * W11 · A4 稿「mine-input 设置」入口列表：
 * 通用 / 输入方案 / 自适应学习 / 采集与上下文 / AI 与同步 / 隐私与数据 / 关于，
 * 每行带实时状态提示（与 macOS 同构 · 采集项 Android 上限如实标注）。
 */
class SettingsActivity : Activity() {

    private lateinit var consent: Prefs.Consent
    private lateinit var pairing: Prefs.Pairing
    private lateinit var settings: Prefs.SettingsStore
    private val hintViews = mutableMapOf<String, TextView>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consent = Prefs.Consent(this)
        pairing = Prefs.Pairing(this)
        settings = Prefs.SettingsStore(this)
        SyncManager.init(this)
        buildUi()
    }

    override fun onResume() {
        super.onResume()
        refreshHints()
    }

    private fun buildUi() {
        val pad = Ui.dp(this, 16f)
        val scroll = ScrollView(this).apply {
            setBackgroundColor(DesignTokens.bg)
            isFillViewport = true
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad * 2)
        }

        root.addView(Ui.title(this, "mine-input 设置"))
        root.addView(Ui.muted(this, "与 macOS 同构 · 采集项 Android 上限如实标注"))

        fun sectionRow(id: String, title: String, section: String) {
            val hint = Ui.muted(this, "")
            hintViews[id] = hint
            val row = Ui.row(this, title, null) { open(section) }
            // 把 hint 插到行内文本列
            (row.getChildAt(0) as LinearLayout).addView(hint)
            root.addView(row)
        }

        root.addView(Ui.heading(this, "输入"))
        sectionRow("general", "通用", SectionActivity.SECTION_GENERAL)
        sectionRow("schema", "输入方案", SectionActivity.SECTION_SCHEMA)
        sectionRow("learn", "自适应学习", SectionActivity.SECTION_LEARN)

        root.addView(Ui.heading(this, "采集与智能"))
        sectionRow("collect", "采集与上下文", SectionActivity.SECTION_COLLECT)
        sectionRow("ai", "AI 与同步", SectionActivity.SECTION_AI)

        root.addView(Ui.heading(this, "数据"))
        sectionRow("privacy", "隐私与数据", SectionActivity.SECTION_PRIVACY)
        sectionRow("about", "关于", SectionActivity.SECTION_ABOUT)

        root.addView(
            Ui.muted(
                this,
                "Android 特有：C2 读屏需开无障碍服务（侧载版自带说明）"
            )
        )

        scroll.addView(root)
        setContentView(scroll)
    }

    private fun open(section: String) {
        startActivity(Intent(this, SectionActivity::class.java).putExtra(SectionActivity.EXTRA_SECTION, section))
    }

    private fun refreshHints() {
        hintViews["general"]?.text = listOfNotNull(
            if (settings.perfMode) "性能模式" else null,
            if (settings.keySound) "按键音" else null,
        ).joinToString(" · ").ifEmpty { "默认" }
        hintViews["schema"]?.text = "五笔86+拼音"
        hintViews["learn"]?.text = listOfNotNull(
            if (settings.learnL1) "L1" else null,
            if (settings.learnL2) "L2" else null,
        ).joinToString(" ").let { if (it.isEmpty()) "全关" else "$it 已开" }
        hintViews["collect"]?.text =
            (if (SyncManager.fuseBlown()) "熔断中 · " else "") +
                "C2 无障碍：${if (consent.c2) "开" else "关"}"
        hintViews["ai"]?.text =
            if (pairing.paired) "本地 Hub · 已连接" else "本地 Hub · 未连接"
        hintViews["privacy"]?.text =
            if (consent.any) "同意：C0=${if (consent.c0) "✓" else "✗"} C2=${if (consent.c2) "✓" else "✗"} 热词=${if (consent.hotword) "✓" else "✗"}"
            else "未同意 · 不上报"
    }
}
