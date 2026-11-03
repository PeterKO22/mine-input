package com.mineinput.ime

import android.inputmethodservice.InputMethodService
import android.view.KeyEvent
import android.view.View

/**
 * mine-input Android 基座 —— Kotlin IMS 骨架（W5）。
 * 已实现：QWERTY 输入 → 组合码（composing）→ 候选栏占位（五笔/拼音混合标签）→ 上屏；
 * PTT 大键按住即说交互（UI 状态机占位，语音管线按技术方案 §6 后续接入）。
 * 引擎接线点：[compose]（librime/自研混合引擎落点）与 [onPttDown]/[onPttUp]（FR2 管线）。
 */
class MineImeService : InputMethodService(), KeyboardView.Listener {

    private lateinit var keyboardView: KeyboardView
    private val composing = StringBuilder()

    override fun onCreateInputView(): View {
        keyboardView = KeyboardView(this)
        keyboardView.listener = this
        return keyboardView
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        refresh("")
    }

    // ---- 键盘事件 ----

    override fun onLetter(ch: Char) {
        composing.append(ch)
        currentInputConnection?.setComposingText(composing, 1)
        refresh("")
    }

    override fun onDelete() {
        if (composing.isNotEmpty()) {
            composing.deleteCharAt(composing.length - 1)
            currentInputConnection?.setComposingText(composing, 1)
        } else {
            currentInputConnection?.deleteSurroundingText(1, 0)
        }
        refresh("")
    }

    override fun onEnter() {
        if (composing.isNotEmpty()) {
            commit(composing.toString())
        } else {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
        refresh("")
    }

    override fun onSpace() {
        if (composing.isNotEmpty() && candidates().isNotEmpty()) {
            // 空码顶字=关（FR1 默认值）：空格不顶首选，仅上屏原始码
            commit(composing.toString())
        } else {
            currentInputConnection?.commitText(" ", 1)
        }
        refresh("")
    }

    override fun onSymbol() {
        // 符号面板占位（W5 范围外）
        refresh("符号面板占位 · 后续接入")
    }

    override fun onCandidate(index: Int) {
        val c = candidates().getOrNull(index) ?: return
        commit(c)
        refresh("")
    }

    // ---- PTT（FR2：按住即说；W5 为 UI 状态机占位，管线见技术方案 §6） ----

    override fun onPttDown() {
        refresh("● 听写中（占位）· 松开上屏 · 移出取消")
    }

    override fun onPttUp() {
        currentInputConnection?.commitText("〈语音转写占位〉", 1)
        refresh("松开→上屏（语音管线占位）")
    }

    // ---- 内部 ----

    private fun commit(text: String) {
        currentInputConnection?.commitText(text, 1)
        composing.clear()
    }

    /**
     * 五笔/拼音混合候选 · 占位实现：
     * 真实混合引擎（形码优先、拼音并联兜底，FR1）后续在 [compose] 落点接入；
     * 此处对少量演示码返回示例候选，其余返回带「五笔/拼音」标签的占位候选，
     * 以驱动候选栏交互（点选→上屏）联调。
     */
    private fun candidates(): List<String> {
        val code = composing.toString()
        if (code.isEmpty()) return emptyList()
        return when (code) {
            "nh" -> listOf("你好·五笔", "拟好·拼音", "你号·拼音", "你好·混输")
            "wubi" -> listOf("五笔·拼音", "五笔86·混输")
            "py" -> listOf("拼音·混输", "拼音·五笔")
            else -> listOf("$code·五笔", "$code·拼音", "$code·混输")
        }
    }

    private fun refresh(status: String) {
        if (::keyboardView.isInitialized) {
            keyboardView.updateState(composing.toString(), candidates(), status)
        }
    }
}
