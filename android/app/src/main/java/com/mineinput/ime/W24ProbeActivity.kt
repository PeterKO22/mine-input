/*
 * mine-input W24 — e2e 探针 Activity（仅 debug 包可用，release 直接 finish）。
 * 三个真实输入框供 w24-e2e.py 断言英文直输/密码框隐私（inputType 是真的，IME 走真 EditorInfo）：
 *   w24_normal   —— 普通文本框（text）
 *   w24_password —— 密码框（textPassword）→ 自动 EN + 采集闸
 *   w24_visible  —— 明文密码框（textVisiblePassword）→ 同上
 * 字段文本经 DebugReceiver w24_fieldtext 读回（密码框 UI dump 不吐明文，须走进程内读取）。
 */
package com.mineinput.ime

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

class W24ProbeActivity : Activity() {

    companion object {
        @Volatile
        var active: W24ProbeActivity? = null

        fun fieldText(which: String): String? = when (which) {
            "normal" -> active?.normal?.text?.toString()
            "password" -> active?.password?.text?.toString()
            "visible" -> active?.visible?.text?.toString()
            else -> null
        }
    }

    private lateinit var normal: EditText
    private lateinit var password: EditText
    private lateinit var visible: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            finish() // release 包不提供探针
            return
        }
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        fun label(text: String) = TextView(this).apply {
            this.text = text
            textSize = 14f
        }

        fun field(desc: String, inputType: Int, hint: String) = EditText(this).apply {
            contentDescription = desc
            this.inputType = inputType
            this.hint = hint
            gravity = Gravity.START
        }

        root.addView(label("W24 探针 · 普通文本框"))
        normal = field(
            "w24_normal",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_NORMAL,
            "normal field",
        )
        root.addView(normal)

        root.addView(label("W24 探针 · 密码框（textPassword）"))
        password = field(
            "w24_password",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            "password field",
        )
        root.addView(password)

        root.addView(label("W24 探针 · 明文密码框（textVisiblePassword）"))
        visible = field(
            "w24_visible",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            "visible password field",
        )
        root.addView(visible)

        setContentView(root)
        active = this
    }

    override fun onDestroy() {
        active = null
        super.onDestroy()
    }
}
