package com.mineinput.ime

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * W5 骨架引导页：启用输入法 → 选择输入法。侧载分发（D12：不上商店）。
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

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

        fun button(text: String, onClick: () -> Unit) = Button(this).apply {
            this.text = text
            setTextColor(DesignTokens.bg)
            setBackgroundColor(DesignTokens.gold)
            setOnClickListener { onClick() }
        }

        root.addView(title("mine-input · Android 基座（W5 骨架）"))
        root.addView(body("五笔86+拼音混输占位 · PTT 大键占位 · 深色科幻视觉"))
        root.addView(body("1. 启用「mine-input 五笔·拼音」输入法"))
        root.addView(button("① 启用输入法") {
            startActivity(Intent(android.provider.Settings.ACTION_INPUT_METHOD_SETTINGS))
        })
        root.addView(body("2. 切换到 mine-input"))
        root.addView(button("② 选择输入法") {
            startActivity(Intent("android.settings.SHOW_INPUT_METHOD_PICKER"))
        })
        root.addView(body("分发：侧载 APK（D12）。颜色 token 见 design/design-language.md。"))

        setContentView(root)
    }
}
