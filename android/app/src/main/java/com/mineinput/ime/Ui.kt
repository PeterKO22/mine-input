package com.mineinput.ime

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView

/**
 * W11 UI 工具箱 —— design/design-language.md 全贯彻（深色科幻）：
 * 分区标题 gold 小字 + 细分割线；开关金/灰；chip 胶囊描边；主按钮金实心微光；
 * 危险按钮暗红；勾选=深底圆+金描边+亮金勾；数字 mono。
 */
object Ui {

    fun dp(ctx: Context, v: Float): Int =
        (v * ctx.resources.displayMetrics.density + 0.5f).toInt()

    fun rounded(fill: Int, stroke: Int = DesignTokens.stroke, radiusDp: Float = 8f, ctx: Context, strokeW: Int = 1): GradientDrawable =
        GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(ctx, radiusDp).toFloat()
            setStroke(dp(ctx, strokeW.toFloat()), stroke)
        }

    fun heading(ctx: Context, text: String): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(DesignTokens.gold)          // 分区标题 gold 小字
        textSize = 11f
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(ctx, 12f), 0, dp(ctx, 4f))
    }

    fun title(ctx: Context, text: String): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(DesignTokens.textTitle)     // 模块标题 14px Bold
        textSize = 15f
        setTypeface(typeface, Typeface.BOLD)
    }

    fun body(ctx: Context, text: String): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(DesignTokens.textBody)
        textSize = 13f
    }

    fun muted(ctx: Context, text: String): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(DesignTokens.textMuted)     // 弱化/辅助
        textSize = 11f
    }

    fun mono(ctx: Context, text: String, color: Int = DesignTokens.white): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(color)
        textSize = 12f
        typeface = Typeface.MONOSPACE            // 数字一律 mono
    }

    fun divider(ctx: Context): View = View(ctx).apply {
        setBackgroundColor(DesignTokens.stroke)  // 一律 1px 细描边
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(ctx, 1f))
    }

    /** chip/徽章：圆角胶囊，深底 + 亮色描边 + 同色字（design-language §4）。 */
    fun chip(ctx: Context, text: String, color: Int): TextView = TextView(ctx).apply {
        this.text = text
        setTextColor(color)
        textSize = 10f
        setTypeface(typeface, Typeface.BOLD)
        gravity = Gravity.CENTER
        setPadding(dp(ctx, 8f), dp(ctx, 3f), dp(ctx, 8f), dp(ctx, 3f))
        background = rounded(DesignTokens.card, color, 4f, ctx, 2)
    }

    fun card(ctx: Context, content: LinearLayout): LinearLayout = content.apply {
        setBackgroundColor(DesignTokens.card)
        background = rounded(DesignTokens.card, DesignTokens.stroke, 8f, ctx)
        setPadding(dp(ctx, 16f), dp(ctx, 12f), dp(ctx, 16f), dp(ctx, 12f))
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.bottomMargin = dp(ctx, 12f)           // 模块间距 12px
        layoutParams = lp
        orientation = LinearLayout.VERTICAL
    }

    fun column(ctx: Context): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.bottomMargin = dp(ctx, 8f)
        layoutParams = lp
    }

    /** 设置行（A4/M4–M7 形态）：标题 + 副标题 + ›。 */
    fun row(ctx: Context, titleText: String, hint: String?, onClick: (() -> Unit)? = null): LinearLayout {
        val l = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(ctx, 10f), 0, dp(ctx, 10f))
            if (onClick != null) {
                isClickable = true
                background = rounded(DesignTokens.card, DesignTokens.stroke, 8f, ctx)
                setOnClickListener { onClick() }
            }
        }
        val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(title(ctx, titleText))
        if (hint != null) texts.addView(muted(ctx, hint))
        val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        l.addView(texts, lp)
        l.addView(TextView(ctx).apply {
            text = "›"
            setTextColor(DesignTokens.textMuted)
            textSize = 18f
        })
        return l
    }

    /** 开关行：金=开、暗灰=关（design-language §4）。 */
    fun toggleRow(
        ctx: Context,
        titleText: String,
        hint: String?,
        checked: Boolean,
        onChecked: (Boolean) -> Unit,
    ): LinearLayout {
        val l = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(ctx, 8f), 0, dp(ctx, 8f))
        }
        val texts = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
        }
        texts.addView(title(ctx, titleText))
        if (hint != null) texts.addView(muted(ctx, hint))
        val lp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        l.addView(texts, lp)
        val sw = Switch(ctx).apply {
            isChecked = checked
            thumbTintList = ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
                intArrayOf(DesignTokens.gold, DesignTokens.textMuted)   // 金=开、暗灰=关
            )
            trackTintList = ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
                intArrayOf(DesignTokens.stroke, DesignTokens.stroke)
            )
            setOnCheckedChangeListener { _, v -> onChecked(v) }
        }
        l.addView(sw)
        // 点行也能切换
        l.setOnClickListener { sw.isChecked = !sw.isChecked }
        return l
    }

    /** 勾选行（知情同意清单）：深底圆 + 金描边 + 亮金勾。 */
    fun checkRow(
        ctx: Context,
        chipText: String,
        chipColor: Int,
        titleText: String,
        hint: String?,
        checked: Boolean,
        onToggle: (Boolean) -> Unit,
    ): LinearLayout {
        val dot = CheckDotView(ctx).apply { isChecked = checked }
        val l = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 8f), dp(ctx, 10f), dp(ctx, 8f), dp(ctx, 10f))
            background = rounded(DesignTokens.card, DesignTokens.stroke, 8f, ctx)
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.bottomMargin = dp(ctx, 8f)
            layoutParams = lp
            isClickable = true
            setOnClickListener {
                dot.isChecked = !dot.isChecked
                onToggle(dot.isChecked)
            }
        }
        l.addView(dot, LinearLayout.LayoutParams(dp(ctx, 22f), dp(ctx, 22f)))
        val mid = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 10f), 0, dp(ctx, 8f), 0)
        }
        val head = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(chip(ctx, chipText, chipColor))
        val t = title(ctx, titleText).apply {
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.leftMargin = dp(ctx, 8f)
            layoutParams = lp
        }
        head.addView(t)
        mid.addView(head)
        if (hint != null) mid.addView(muted(ctx, hint))
        l.addView(mid, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        return l
    }

    fun button(ctx: Context, text: String, style: Style, onClick: () -> Unit): TextView =
        TextView(ctx).apply {
            this.text = text
            textSize = 14f
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(dp(ctx, 16f), dp(ctx, 12f), dp(ctx, 16f), dp(ctx, 12f))
            isClickable = true
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.bottomMargin = dp(ctx, 8f)
            layoutParams = lp
            when (style) {
                Style.PRIMARY -> {   // 主按钮：实心暖金 + 微光晕 + 深色字
                    setTextColor(DesignTokens.bg)
                    background = rounded(DesignTokens.gold, DesignTokens.gold, 6f, ctx)
                }
                Style.SECONDARY -> { // 次按钮：透明/深底 + 细描边 + 浅字，无光晕
                    setTextColor(DesignTokens.textBody)
                    background = rounded(DesignTokens.card, DesignTokens.stroke, 6f, ctx)
                }
                Style.DANGER -> {    // 危险按钮：暗红填充 + 红描边
                    setTextColor(DesignTokens.red)
                    background = rounded(DesignTokens.card, DesignTokens.red, 6f, ctx, 2)
                }
            }
            setOnClickListener { onClick() }
        }

    fun input(ctx: Context, hint: String, initial: String = ""): EditText = EditText(ctx).apply {
        this.hint = hint
        setTextColor(DesignTokens.textBody)
        setHintTextColor(DesignTokens.textMuted)
        textSize = 14f
        typeface = Typeface.MONOSPACE
        setSingleLine(true)
        setPadding(dp(ctx, 12f), dp(ctx, 10f), dp(ctx, 12f), dp(ctx, 10f))
        background = rounded(DesignTokens.bg, DesignTokens.stroke, 6f, ctx)
        setText(initial)
    }

    enum class Style { PRIMARY, SECONDARY, DANGER }
}

/** 勾选点：深底圆 + 金描边 + 亮金勾（design-language §4）。 */
class CheckDotView(context: android.content.Context) : View(context) {
    var isChecked: Boolean = false
        set(v) {
            field = v
            invalidate()
        }

    private val density = resources.displayMetrics.density
    private val paintFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val paintStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
    }
    private val paintCheck = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.2f * density
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    override fun onDraw(canvas: Canvas) {
        val r = minOf(width, height) / 2f - 2 * density
        val cx = width / 2f
        val cy = height / 2f
        paintFill.color = DesignTokens.card
        canvas.drawCircle(cx, cy, r, paintFill)
        paintStroke.color = if (isChecked) DesignTokens.gold else DesignTokens.stroke
        canvas.drawCircle(cx, cy, r, paintStroke)
        if (isChecked) {
            paintCheck.color = DesignTokens.gold
            val p = Path().apply {
                moveTo(cx - r * 0.45f, cy)
                lineTo(cx - r * 0.1f, cy + r * 0.38f)
                lineTo(cx + r * 0.5f, cy - r * 0.38f)
            }
            canvas.drawPath(p, paintCheck)
        }
    }
}
