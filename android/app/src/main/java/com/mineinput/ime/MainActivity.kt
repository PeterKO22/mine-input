package com.mineinput.ime

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView

/**
 * W5 骨架引导页（启用输入法 → 选择输入法）+ W11 集成：
 *   首次启动路由到 A5 知情同意/配对流程；设置入口（A4）；同意/配对状态位展示。
 * 侧载分发（D12：不上商店）。
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 首次启动 → 知情同意 + Hub 配对（A5 稿；FR8 逐项显式同意）
        if (!Prefs.Consent(this).firstLaunchDone) {
            startActivity(Intent(this, ConsentActivity::class.java))
            finish()
            return
        }

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(DesignTokens.bg)
            setPadding(pad, pad * 3, pad, pad)
        }

        fun title(text: String) = TextView(this).apply {
            this.text = text
            setTextColor(DesignTokens.gold)
            textSize = 16f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

        fun body(text: String) = TextView(this).apply {
            this.text = text
            setTextColor(DesignTokens.textBody)
            textSize = 13f
        }

        fun button(text: String, onClick: () -> Unit) = Ui.button(this, text, Ui.Style.PRIMARY, onClick)

        root.addView(title("mine-input · Android 基座（W5 骨架 + W11）"))
        root.addView(body("五笔86+拼音混输占位 · PTT 大键占位 · 深色科幻视觉"))

        // 状态位展示（同意 / 配对 / 熔断）
        val consent = Prefs.Consent(this)
        val pairing = Prefs.Pairing(this)
        val settings = Prefs.SettingsStore(this)
        val chips = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        fun addChip(text: String, color: Int) {
            val tv = Ui.chip(this, text, color)
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            lp.leftMargin = pad / 3
            chips.addView(tv, lp)
        }
        addChip("C0 ${if (consent.c0) "✓" else "✗"}", if (consent.c0) DesignTokens.cyan else DesignTokens.textMuted)
        addChip("C2 ${if (consent.c2) "✓" else "✗"}", if (consent.c2) DesignTokens.red else DesignTokens.textMuted)
        addChip("热词 ${if (consent.hotword) "✓" else "✗"}", if (consent.hotword) DesignTokens.gold else DesignTokens.textMuted)
        addChip(if (pairing.paired) "Hub 已连接" else "Hub 未连接", if (pairing.paired) DesignTokens.green else DesignTokens.textMuted)
        if (settings.fuseBlown) {
            addChip("熔断中", DesignTokens.red)
        }
        root.addView(chips)

        root.addView(body("1. 启用「mine-input 五笔·拼音」输入法"))
        root.addView(button("① 启用输入法") {
            startActivity(Intent(android.provider.Settings.ACTION_INPUT_METHOD_SETTINGS))
        })
        root.addView(body("2. 切换到 mine-input"))
        root.addView(button("② 选择输入法") {
            startActivity(Intent("android.settings.SHOW_INPUT_METHOD_PICKER"))
        })
        root.addView(button("⚙ 打开设置（A4）") {
            startActivity(Intent(this, SettingsActivity::class.java))
        })
        root.addView(body("分发：侧载 APK（D12）。颜色 token 见 design/design-language.md。"))

        setContentView(root)
    }
}
