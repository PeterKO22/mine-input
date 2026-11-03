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
    }

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
    private var shiftOn: Boolean = false

    private val keyRects = mutableListOf<KeyRect>()
    private val candidateRects = mutableListOf<RectF>()
    private var pressed: KeyRect? = null
    private var pttHeld = false

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

    fun updateState(composing: String, candidates: List<String>, statusLine: String) {
        this.composing = composing
        this.candidates = candidates
        this.statusLine = statusLine
        if (width > 0) layoutKeys(width) // 候选数量变化 → 重排候选栏命中区
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

        // 状态行（听写中 = cyan；其余弱化）
        paintTextMono.color = if (pttHeld) DesignTokens.cyan else DesignTokens.textMuted
        paintTextMono.textSize = dp(11f)
        val statusText = if (composing.isNotEmpty() && statusLine.isEmpty()) "码：$composing" else statusLine
        canvas.drawText(
            statusText,
            keyMargin + dp(4f),
            keyGap + candidateHeight + statusHeight / 2 - (paintTextMono.descent() + paintTextMono.ascent()) / 2,
            paintTextMono,
        )

        // 键帽
        for (kr in keyRects) {
            drawKey(canvas, kr)
        }
    }

    private fun drawKey(canvas: Canvas, kr: KeyRect) {
        val isPressed = pressed === kr
        val isPtt = kr.def.kind == Kind.PTT
        paintFill.color = when {
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
                if (kr?.def?.kind == Kind.PTT || pttHeld) {
                    pttHeld = false
                    listener?.onPttUp()
                }
                invalidate()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (pttHeld) {
                    pttHeld = false
                    listener?.onPttUp()
                }
                pressed = null
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}
