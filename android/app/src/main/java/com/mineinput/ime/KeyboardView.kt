package com.mineinput.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.view.MotionEvent
import android.view.View
import kotlin.math.min

/**
 * W5 骨架键盘视图：QWERTY 键帽 + 候选栏（五笔/拼音混合占位）+ PTT 大键。
 * 视觉对齐 design/design-language.md：键帽 card+stroke，PTT 主按钮金实心（长按态青光），
 * 候选序号 gold mono，当前候选金填充微光。键位排布遵循平台习惯，仅换肤不改形。
 */
class KeyboardView constructor(
    context: Context,
) : View(context) {

    interface Listener {
        fun onLetter(ch: Char)
        fun onDelete()
        fun onEnter()
        fun onSpace()
        fun onSymbol()
        fun onCandidate(index: Int)
        fun onPttDown()
        fun onPttUp()
        fun onPttCancel() // W14：滑出 PTT 键 / 返回键取消（不上屏）
        fun onSettings() // W11：状态条「⚙ 设置」入口
    }

    /** W11 状态位（FR8 采集状态常显）：label + 是否激活 + 激活色。 */
    data class Bit(val label: String, val active: Boolean, val color: Int)

    var listener: Listener? = null

    private enum class Kind { CHAR, ENTER, PTT, SHIFT, DELETE, SPACE, SYMBOL }

    private data class KeyDef(
        val label: String,
        val kind: Kind = Kind.CHAR,
        val weight: Float = 1f,
    )

    private class KeyRect(val def: KeyDef, val rect: RectF)

    private val rows: List<List<KeyDef>> = listOf(
        "qwertyuiop".map { KeyDef(it.toString()) },
        "asdfghjkl".map { KeyDef(it.toString()) },
        listOf(KeyDef("⇧", Kind.SHIFT, 1.4f)) +
            "zxcvbnm".map { KeyDef(it.toString()) } +
            listOf(KeyDef("⌫", Kind.DELETE, 1.4f)),
        listOf(
            KeyDef("?123", Kind.SYMBOL, 1.4f),
            KeyDef("，"),
            KeyDef("空格", Kind.SPACE, 3.2f),
            KeyDef("。"),
            KeyDef("按住说话", Kind.PTT, 2.2f),
            KeyDef("⏎", Kind.ENTER, 1.4f),
        ),
    )

    // 状态（由 MineImeService 驱动）
    private var composing: String = ""
    private var candidates: List<String> = emptyList()
    private var statusLine: String = ""
    private var stateBits: List<Bit> = emptyList()
    private var shiftOn: Boolean = false

    private val keyRects = mutableListOf<KeyRect>()
    private val candidateRects = mutableListOf<RectF>()
    private var gearRect: RectF = RectF() // W11 设置入口命中区
    private var pressed: KeyRect? = null
    private var pttHeld = false
    private var pttOverlayActive = false // W14：听写中 → 候选区显示滚动转写
    private var pttRolling = ""
    private var pttCancelArmed = false // W14：滑出 PTT 键 = 松开取消
    private var statusError = false // W14：失败提示（红字）

    private val density = resources.displayMetrics.density
    private fun dp(v: Float): Float = v * density

    private val keyGap = dp(6f)
    private val keyMargin = dp(6f)
    private val keyHeight = dp(44f)
    private val candidateHeight = dp(42f)
    private val statusHeight = dp(22f)
    private val radius = dp(6f)   // 图标容器/小按钮 4px 档 → 键帽取 6dp（卡片 8dp 档）

    private val paintFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val paintStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)      // 一律 1px 细描边
    }
    private val paintText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    }
    private val paintTextMono = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.MONOSPACE   // 数字一律 mono
    }

    fun updateState(
        composing: String,
        candidates: List<String>,
        statusLine: String,
        bits: List<Bit> = emptyList(),
        error: Boolean = false, // W14：失败提示（如「请重说」）红字显示
    ) {
        this.composing = composing
        this.candidates = candidates
        this.statusLine = statusLine
        this.stateBits = bits
        this.statusError = error
        if (width > 0) layoutKeys(width) // 候选数量变化 → 重排候选栏命中区
        invalidate()
    }

    /** W14：PTT 候选区滚动转写覆盖层（听写中候选栏显示实时转写，随说话滚动刷新）。 */
    fun setPttOverlay(active: Boolean, rolling: String) {
        pttOverlayActive = active
        pttRolling = rolling
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = (candidateHeight + statusHeight + rows.size * keyHeight +
            (rows.size + 1) * keyGap + keyMargin).toInt()
        setMeasuredDimension(w, h)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        layoutKeys(w)
    }

    private fun layoutKeys(w: Int) {
        keyRects.clear()
        candidateRects.clear()
        val innerWidth = w - 2 * keyMargin
        var y = keyGap
        // 候选栏
        if (candidates.isNotEmpty()) {
            val n = min(candidates.size, 6)
            val cw = innerWidth / n
            for (i in 0 until n) {
                candidateRects.add(RectF(keyMargin + i * cw, y, keyMargin + (i + 1) * cw, y + candidateHeight))
            }
        }
        y += candidateHeight + keyGap
        // W11：状态条右侧「⚙ 设置」入口命中区 + 状态位
        gearRect = RectF(w - keyMargin - dp(64f), y, w - keyMargin, y + statusHeight)
        y += statusHeight + keyGap
        for (row in rows) {
            val totalWeight = row.sumOf { it.weight.toDouble() }.toFloat()
            var x = keyMargin
            for (def in row) {
                val kw = innerWidth * def.weight / totalWeight
                keyRects.add(KeyRect(def, RectF(x, y, x + kw - keyGap, y + keyHeight)))
                x += kw
            }
            y += keyHeight + keyGap
        }
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(DesignTokens.bg)

        if (pttOverlayActive) {
            // W14：听写中 → 候选区显示滚动转写（尾部跟随，实时刷新；提交后回到候选栏）
            val strip = RectF(keyMargin, keyGap, width - keyMargin, keyGap + candidateHeight)
            paintFill.color = DesignTokens.card
            paintFill.setShadowLayer(dp(6f), 0f, 0f, DesignTokens.cyan)
            canvas.drawRoundRect(strip, radius, radius, paintFill)
            paintFill.setShadowLayer(0f, 0f, 0f, 0)
            paintStroke.color = DesignTokens.cyan
            canvas.drawRoundRect(strip, radius, radius, paintStroke)
            paintText.color = DesignTokens.textBody
            paintText.textSize = dp(13f)
            paintText.textAlign = Paint.Align.LEFT
            val maxW = strip.width() - dp(16f)
            var show = pttRolling
            if (paintText.measureText(show) > maxW) {
                // 尾部跟随（滚动）：保留能放下的尾段
                while (show.isNotEmpty() && paintText.measureText(show) > maxW) show = show.substring(1)
                show = "…$show"
            }
            val cy = strip.centerY() - (paintText.descent() + paintText.ascent()) / 2
            canvas.drawText(show, strip.left + dp(8f), cy, paintText)
            paintText.textAlign = Paint.Align.CENTER
        } else {
        // 候选栏（M1 映射：序号 gold mono，当前候选金填充微光）
        for ((i, rect) in candidateRects.withIndex()) {
            val label = candidates.getOrNull(i) ?: continue
            val selected = i == 0
            paintFill.color = if (selected) DesignTokens.gold else DesignTokens.card
            paintFill.setShadowLayer(if (selected) dp(6f) else 0f, 0f, 0f, DesignTokens.gold)
            canvas.drawRoundRect(rect, radius, radius, paintFill)
            paintFill.setShadowLayer(0f, 0f, 0f, 0)
            paintStroke.color = if (selected) DesignTokens.gold else DesignTokens.stroke
            canvas.drawRoundRect(rect, radius, radius, paintStroke)
            paintTextMono.color = if (selected) DesignTokens.bg else DesignTokens.gold
            paintTextMono.textSize = dp(11f)
            val idxX = rect.left + dp(12f)
            val cy = rect.centerY() - (paintTextMono.descent() + paintTextMono.ascent()) / 2
            canvas.drawText("${i + 1}", idxX, cy, paintTextMono)
            paintText.color = if (selected) DesignTokens.bg else DesignTokens.textBody
            paintText.textSize = dp(13f)
            canvas.drawText(label, (rect.left + rect.right) / 2 + dp(8f), cy, paintText)
        }
        }

        // 状态行（听写中 = cyan；失败提示 = red；其余弱化）
        val statusY = keyGap + candidateHeight + statusHeight / 2
        paintTextMono.color = when {
            pttHeld -> DesignTokens.cyan
            statusError -> DesignTokens.red
            else -> DesignTokens.textMuted
        }
        paintTextMono.textSize = dp(11f)
        val statusText = if (composing.isNotEmpty() && statusLine.isEmpty()) "码：$composing" else statusLine
        canvas.drawText(
            statusText,
            keyMargin + dp(4f),
            statusY - (paintTextMono.descent() + paintTextMono.ascent()) / 2,
            paintTextMono,
        )

        // W11 状态位（FR8 采集状态常显）：C0/C2/HW/熔断/Hub 小胶囊
        paintTextMono.textSize = dp(9f)
        var bx = gearRect.left - dp(6f)
        for (bit in stateBits.asReversed()) {
            val label = if (bit.active) "${bit.label}✓" else "${bit.label}·"
            val tw = paintTextMono.measureText(label)
            val chipW = tw + dp(10f)
            val rect = RectF(bx - chipW, statusY - statusHeight / 2 + dp(3f), bx, statusY + statusHeight / 2 - dp(3f))
            paintFill.color = DesignTokens.card
            canvas.drawRoundRect(rect, dp(4f), dp(4f), paintFill)
            paintStroke.color = if (bit.active) bit.color else DesignTokens.stroke
            canvas.drawRoundRect(rect, dp(4f), dp(4f), paintStroke)
            paintTextMono.color = if (bit.active) bit.color else DesignTokens.textMuted
            canvas.drawText(label, rect.centerX(), statusY - (paintTextMono.descent() + paintTextMono.ascent()) / 2, paintTextMono)
            bx = rect.left - dp(4f)
        }

        // W11 设置入口 chip（「⚙ 设置」）
        paintFill.color = DesignTokens.card
        canvas.drawRoundRect(gearRect, dp(4f), dp(4f), paintFill)
        paintStroke.color = DesignTokens.stroke
        canvas.drawRoundRect(gearRect, dp(4f), dp(4f), paintStroke)
        paintTextMono.color = DesignTokens.textMuted
        paintTextMono.textSize = dp(9f)
        canvas.drawText("⚙ 设置", gearRect.centerX(), statusY - (paintTextMono.descent() + paintTextMono.ascent()) / 2, paintTextMono)

        // 键帽
        for (kr in keyRects) {
            drawKey(canvas, kr)
        }
    }

    private fun drawKey(canvas: Canvas, kr: KeyRect) {
        val isPressed = pressed === kr
        val isPtt = kr.def.kind == Kind.PTT
        paintFill.color = when {
            isPtt && pttHeld && pttCancelArmed -> DesignTokens.red // W14：滑出取消态
            isPtt && pttHeld -> DesignTokens.cyan   // PTT 长按态青光
            isPtt -> DesignTokens.gold              // PTT 主按钮金实心
            isPressed -> DesignTokens.stroke
            else -> DesignTokens.card
        }
        if (isPtt && pttHeld) {
            paintFill.setShadowLayer(dp(10f), 0f, 0f, DesignTokens.cyan)
        }
        canvas.drawRoundRect(kr.rect, radius, radius, paintFill)
        paintFill.setShadowLayer(0f, 0f, 0f, 0)
        paintStroke.color = if (isPtt) DesignTokens.gold else DesignTokens.stroke
        canvas.drawRoundRect(kr.rect, radius, radius, paintStroke)

        var label = kr.def.label
        if (kr.def.kind == Kind.PTT && pttHeld) {
            label = if (pttCancelArmed) "松开取消" else "松开上屏" // W14
        }
        if (kr.def.kind == Kind.CHAR && shiftOn) label = label.uppercase()
        paintText.color = when {
            isPtt && pttHeld -> DesignTokens.bg
            isPtt -> DesignTokens.bg
            kr.def.kind == Kind.CHAR -> DesignTokens.textBody
            else -> DesignTokens.textTitle
        }
        paintText.textSize = if (isPtt) dp(13f) else dp(16f)
        val cy = kr.rect.centerY() - (paintText.descent() + paintText.ascent()) / 2
        canvas.drawText(label, kr.rect.centerX(), cy, paintText)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // W11：状态条「⚙ 设置」入口
                if (gearRect.contains(event.x, event.y)) {
                    listener?.onSettings()
                    return true
                }
                val cand = candidateRects.indexOfFirst { it.contains(event.x, event.y) }
                if (cand >= 0 && cand < candidates.size) {
                    listener?.onCandidate(cand)
                    return true
                }
                val kr = keyRects.firstOrNull { it.rect.contains(event.x, event.y) } ?: return true
                pressed = kr
                if (kr.def.kind == Kind.PTT) {
                    pttHeld = true
                    listener?.onPttDown()
                }
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                val kr = pressed
                pressed = null
                if (kr != null && kr.def.kind == Kind.PTT && pttHeld) {
                    // W14：PTT 松开语义——键内松开=上屏；滑出键外（或已触发取消）=取消
                    val inside = kr.rect.contains(event.x, event.y)
                    val cancelled = pttCancelArmed || !inside
                    pttHeld = false
                    pttCancelArmed = false
                    if (cancelled) {
                        android.util.Log.i("W14", "PTT_CANCEL_REASON slide-out")
                        listener?.onPttCancel()
                    } else {
                        listener?.onPttUp()
                    }
                    invalidate()
                    return true
                }
                if (kr != null && kr.rect.contains(event.x, event.y)) {
                    when (kr.def.kind) {
                        Kind.CHAR -> {
                            var ch = kr.def.label[0]
                            if (shiftOn) {
                                ch = ch.uppercaseChar()
                                shiftOn = false
                            }
                            listener?.onLetter(ch)
                        }
                        Kind.DELETE -> listener?.onDelete()
                        Kind.ENTER -> listener?.onEnter()
                        Kind.SPACE -> listener?.onSpace()
                        Kind.SYMBOL -> listener?.onSymbol()
                        Kind.SHIFT -> shiftOn = !shiftOn
                        Kind.PTT -> {}
                    }
                }
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                // W14：PTT 滑出取消手势（滑出键外=松开取消；滑回=恢复上屏）
                val kr = pressed
                if (pttHeld && kr != null && kr.def.kind == Kind.PTT) {
                    val slop = dp(12f)
                    val outside = event.x < kr.rect.left - slop || event.x > kr.rect.right + slop ||
                        event.y < kr.rect.top - slop || event.y > kr.rect.bottom + slop
                    if (outside != pttCancelArmed) {
                        pttCancelArmed = outside
                        invalidate()
                    }
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (pttHeld) {
                    pttHeld = false
                    pttCancelArmed = false
                    listener?.onPttCancel() // W14：系统夺走手势按取消语义（不上屏）
                }
                pressed = null
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}
