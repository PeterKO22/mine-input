package com.mineinput.ime

import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.view.KeyEvent
import android.view.View
import com.mineinput.ime.sync.SyncManager
import org.json.JSONObject

/**
 * mine-input Android 基座 —— Kotlin IMS 骨架（W5）+ W11 集成。
 * 已实现：QWERTY 输入 → 组合码（composing）→ 候选栏占位（五笔/拼音混合标签）→ 上屏；
 * PTT 大键按住即说交互（UI 状态机占位，语音管线按技术方案 §6 后续接入）。
 *
 * W11 集成：
 *   - 状态位展示：C0/C2/热词同意位、熔断位、Hub 连接位（键盘状态条常显，FR8）；
 *   - 设置入口：状态条右侧「⚙ 设置」；
 *   - 真实上报：候选点选 → candidate_pick 事件、PTT 松开 → voice_session 事件
 *     （C0 同意 + 未熔断才入队上报，撤回同意后不再上报；静默入离线队列）。
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
        val code = composing.toString()
        val c = candidates().getOrNull(index) ?: return
        commit(c)
        // W11 真实上报：candidate_pick 交互事件 + L1 词典/L2 计数学习（同意门控，静默）
        learnAndReport(code, c)
        refresh("")
    }

    // ---- PTT（FR2：按住即说；W5 为 UI 状态机占位，管线见技术方案 §6） ----

    override fun onPttDown() {
        refresh("● 听写中（占位）· 松开上屏 · 移出取消")
    }

    override fun onPttUp() {
        currentInputConnection?.commitText("〈语音转写占位〉", 1)
        // W11 真实上报：voice_session 事件（C0 同意 + 未熔断才上报）
        SyncManager.init(this)
        SyncManager.recordInteraction(
            JSONObject()
                .put("ts", System.currentTimeMillis())
                .put("device_id", Prefs.Pairing(this).deviceId)
                .put("app_id", "com.mineinput.ime")
                .put("kind", "voice_session")
                .put("text_in", "")
                .put("text_out", "〈语音转写占位〉")
        )
        refresh("松开→上屏（语音管线占位）")
    }

    // ---- W11：设置入口（键盘状态条「⚙ 设置」） ----

    override fun onSettings() {
        startActivity(
            Intent(this, SettingsActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    // ---- 内部 ----

    private fun commit(text: String) {
        currentInputConnection?.commitText(text, 1)
        composing.clear()
    }

    /** L1 词典 / L2 习惯计数 + 事件上报（全部受同意/熔断门控；撤回同意后不再上报）。 */
    private fun learnAndReport(code: String, picked: String) {
        SyncManager.init(this)
        val settings = Prefs.SettingsStore(this)
        val consent = Prefs.Consent(this)
        val now = System.currentTimeMillis()
        if (!settings.fuseBlown && consent.c0) {
            if (settings.learnL1) {
                SyncManager.store.putUserdb("wubi/$code", picked, now) // userdb 时间戳取新
            }
            if (settings.learnL2) {
                SyncManager.store.addCounter("l2_pick", 1L)            // 计数器增量累加
            }
        }
        SyncManager.recordInteraction(
            JSONObject()
                .put("ts", now)
                .put("device_id", Prefs.Pairing(this).deviceId)
                .put("app_id", "com.mineinput.ime")
                .put("kind", "candidate_pick")
                .put("text_in", code)
                .put("text_out", picked)
        )
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
            SyncManager.init(this)
            val consent = Prefs.Consent(this)
            val pairing = Prefs.Pairing(this)
            val settings = Prefs.SettingsStore(this)
            // 状态位（FR8 采集状态常显）：同意位 + 熔断位 + Hub 连接位
            val bits = listOf(
                KeyboardView.Bit("C0", consent.c0, DesignTokens.cyan),
                KeyboardView.Bit("C2", consent.c2, DesignTokens.red),
                KeyboardView.Bit("HW", consent.hotword, DesignTokens.gold),
                KeyboardView.Bit("熔断", settings.fuseBlown, DesignTokens.red),
                KeyboardView.Bit("Hub", pairing.paired, DesignTokens.green),
            )
            val cands = candidates()
            val statusText = when {
                status.isNotEmpty() -> status
                composing.isNotEmpty() && cands.isNotEmpty() -> "码：$composing · 候选 ${cands.size}"
                composing.isNotEmpty() -> "码：$composing"
                settings.fuseBlown -> "熔断中 · 采集与上报已停止"
                !consent.any -> "未同意采集 · 不上报"
                else -> "就绪"
            }
            keyboardView.updateState(composing.toString(), cands, statusText, bits)
        }
    }
}
