package com.mineinput.ime

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.mineinput.ime.sync.SyncManager

/**
 * W11 · A5 稿「Android 首次配对 + 同意」：
 *   连接你的 AI Hub → [扫码窗口占位] → 或输入配对码（真连）→
 *   同意清单（C0 / C2 / 语音热词同步，逐项显式勾选，无默认全开）→ 配对并继续。
 * FR8：高敏采集逐项显式同意、随时可撤回；C0=青、C2=红（高敏/重要）、热词=金（主线）。
 */
class ConsentActivity : Activity() {

    private lateinit var consent: Prefs.Consent
    private lateinit var pairing: Prefs.Pairing
    private var statusView: TextView? = null
    private var codeInput: TextView? = null
    private var hubInput: TextView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consent = Prefs.Consent(this)
        pairing = Prefs.Pairing(this)

        val pad = Ui.dp(this, 16f)
        val scroll = ScrollView(this).apply {
            setBackgroundColor(DesignTokens.bg)
            isFillViewport = true
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad * 2)
        }

        // ---- 标题区（A5） ----
        root.addView(Ui.title(this, "连接你的 AI Hub"))
        root.addView(Ui.muted(this, "习惯与数据只进你自己的服务器"))

        // ---- 扫码窗口（UI 占位） ----
        val scan = FrameLayout(this).apply {
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Ui.dp(this@ConsentActivity, 160f))
            lp.topMargin = Ui.dp(this@ConsentActivity, 12f)
            lp.bottomMargin = Ui.dp(this@ConsentActivity, 12f)
            layoutParams = lp
            background = Ui.rounded(DesignTokens.card, DesignTokens.stroke, 8f, this@ConsentActivity)
            addView(TextView(this@ConsentActivity).apply {
                text = "[ 扫码窗口 ]\n扫码配对（占位 · 后续接相机扫码）"
                setTextColor(DesignTokens.textMuted)
                textSize = 12f
                gravity = Gravity.CENTER
                setPadding(Ui.dp(this@ConsentActivity, 16f), Ui.dp(this@ConsentActivity, 16f), Ui.dp(this@ConsentActivity, 16f), Ui.dp(this@ConsentActivity, 16f))
            })
        }
        root.addView(scan)

        // ---- 配对码输入（真连） ----
        root.addView(Ui.muted(this, "或输入配对码"))
        hubInput = Ui.input(this, "Hub 地址（模拟器默认 10.0.2.2:8088）", pairing.baseUrl)
        root.addView(hubInput as TextView)
        codeInput = Ui.input(this, "配对码：XXXX-XXXX-XXXX 或 用户名:密码")
        root.addView(codeInput as TextView)

        // ---- 同意清单（与 macOS 同一份）逐项勾选、无默认全开 ----
        root.addView(Ui.heading(this, "同意清单（与 macOS 同一份）"))
        root.addView(
            Ui.checkRow(
                this, "C0", DesignTokens.cyan,
                "基础上下文（推荐）", "按键会话/候选选择等基础上下文 · 本地学习与同步",
                consent.c0,
            ) { v -> consent.c0 = v; consent.touch() }
        )
        root.addView(
            Ui.checkRow(
                this, "C2", DesignTokens.red,
                "读屏上下文（无障碍服务）", "高敏采集 · Android 上限：需开启无障碍服务，采集项如实标注",
                consent.c2,
            ) { v -> consent.c2 = v; consent.touch() }
        )
        root.addView(
            Ui.checkRow(
                this, "同步", DesignTokens.gold,
                "语音热词同步", "热词表在设备与 Hub 之间同步",
                consent.hotword,
            ) { v -> consent.hotword = v; consent.touch() }
        )
        root.addView(Ui.muted(this, "随时可在设置中撤回任一项 · 无默认全开，逐项显式同意"))

        // ---- 主按钮：配对并继续 ----
        root.addView(
            Ui.button(this, "配对并继续", Ui.Style.PRIMARY) {
                val code = (codeInput as TextView).text.toString()
                val hub = (hubInput as TextView).text.toString().trim()
                if (hub.isNotEmpty()) pairing.baseUrl = hub
                consent.touch()
                status("配对中…")
                Thread {
                    val result = SyncManager.pair(code)
                    runOnUiThread {
                        if (result.startsWith("PAIR_OK")) {
                            consent.firstLaunchDone = true
                            status("✓ $result · 同意已记录（C0=${consent.c0} C2=${consent.c2} 热词=${consent.hotword}）")
                            startActivity(android.content.Intent(this, MainActivity::class.java).apply {
                                addFlags(android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            })
                            finish()
                        } else {
                            status("✗ $result · 请检查 Hub 地址与配对码")
                        }
                    }
                }.start()
            }
        )
        statusView = Ui.muted(this, "未配对 · Hub 默认 ${pairing.baseUrl}")
        root.addView(statusView as TextView)

        scroll.addView(root)
        setContentView(scroll)
    }

    private fun status(s: String) {
        statusView?.text = s
        statusView?.setTextColor(if (s.startsWith("✗")) DesignTokens.red else DesignTokens.green)
    }
}
