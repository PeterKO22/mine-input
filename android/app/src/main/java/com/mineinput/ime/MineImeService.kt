package com.mineinput.ime

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import com.mineinput.ime.engine.EngineCandidate
import com.mineinput.ime.engine.MixedEngine
import com.mineinput.ime.sync.SyncManager
import com.mineinput.ime.voice.AsrEngine
import com.mineinput.ime.voice.ModelManager
import com.mineinput.ime.voice.PttRecorder
import com.mineinput.ime.voice.VoiceInput
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * mine-input Android 基座 —— Kotlin IMS 骨架（W5）+ W11 集成 + W14 语音 + W16 混输引擎。
 * 已实现：QWERTY 输入 → librime 混输引擎（W16，ping_wubi_mixed schema：五笔86 形码优先 +
 * 拼音并联兜底 + z 反查注释）→ 候选栏真数据 → 选词经 W5 commit 通道上屏；
 * PTT 大键按住即说（W14 真管线：AudioRecord 16k mono 内存缓冲 → VAD 分段转写 →
 * 候选区滚动 → 松开经 W5 commit 通道上屏；滑出/返回取消；低置信提示重说不瞎猜）。
 *
 * W11 集成：
 *   - 状态位展示：C0/C2/热词同意位、熔断位、Hub 连接位（键盘状态条常显，FR8）；
 *   - 设置入口：状态条右侧「⚙ 设置」；
 *   - 真实上报：候选点选 → candidate_pick 事件、PTT 松开 → voice_session 事件
 *     （C0 同意 + 未熔断才入队上报，撤回同意后不再上报；静默入离线队列）。
 * 引擎接线（W16，engine/MixedEngine）：onLetter/onKey/candidates/onCandidate 全部走
 * MixedInputEngine（librime JNI）；首启 IO 线程部署 assets 下 rime 数据（设备端编译码表）。
 *
 * W24（Mac 设计同步）：
 *   - 中/EN 持久切换（工具栏「中/EN」键）：英文态字母/数字/符号直接上屏 ASCII
 *     （语义对齐 Mac schema/default.yaml switch_key: Shift=commit_code，搜狗式），
 *     不过引擎、不等部署，混合场景=中文串中一键插英文；
 *   - 数字/符号直输（?123 面板 Kind.DIRECT）：两态皆 ASCII 直输；中文态数字键顺带选候选；
 *   - 密码框隐私（Mac C1 同步）：焦点进入 textPassword/textVisiblePassword 等密码框 →
 *     自动切 EN + 采集闸关死（SyncManager.collectionPaused，不调 AI/云端）；离开恢复。
 */
class MineImeService : InputMethodService(), KeyboardView.Listener {

    companion object {
        /** W14：调试钩子经此拿活动输入法（上屏通道）。 */
        @Volatile
        var active: MineImeService? = null

        /** W24：隐私/模式日志 tag（w24-e2e 断言）。 */
        const val W24_TAG = "W24"
    }

    private lateinit var keyboardView: KeyboardView
    private val composing = StringBuilder()
    private var pttRecorder: PttRecorder? = null
    @Volatile
    private var pttActive = false

    // ---- W24：中/EN 持久模式 + 密码框隐私状态 ----
    @Volatile
    private var imeEn = false // true=英文直输态（commit_code 语义）
    @Volatile
    private var passwordField = false // 当前焦点是否密码框（采集闸+自动 EN）
    private var modeBeforePassword = false // 进密码框前的模式（离开恢复）
    @Volatile
    private var demoAiCount = 0 // W24：AI 智能候选组标记演示位（真实 AI 来源=TODO 卡）

    /** W24 调试钩子：AI 智能候选组标记演示（前 n 个候选渲染为 AI 组样式）。 */
    fun setDemoAiCount(n: Int) {
        demoAiCount = n
        refresh("")
    }

    fun demoAi(): Int = demoAiCount

    override fun onCreate() {
        super.onCreate()
        active = this
        // W24：中/EN 持久模式从盘上恢复（跨会话保留）
        imeEn = Prefs.SettingsStore(this).imeMode == "en"
        // W16：IO 线程启动混输引擎（首用 fullCheck=设备端编译码表，W15 实测 ≤5s）
        thread(name = "w16-engine-start") {
            MixedEngine.ensureStarted(this) { android.util.Log.i(MixedEngine.TAG, it) }
            if (::keyboardView.isInitialized) keyboardView.post { refresh("") }
        }
    }

    override fun onDestroy() {
        active = null
        pttRecorder?.cancel()
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        keyboardView = KeyboardView(this)
        keyboardView.listener = this
        return keyboardView
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        applyFieldPrivacy(info) // W24：密码框自动 EN + 采集闸
        refresh("")
    }

    // ---- W24：密码框隐私（Mac C1 设计同步） ----

    /** 密码框判定：textPassword / textVisiblePassword / webPassword / numberPassword。 */
    private fun isPasswordInput(inputType: Int): Boolean {
        val cls = inputType and InputType.TYPE_MASK_CLASS
        val vari = inputType and InputType.TYPE_MASK_VARIATION
        return when (cls) {
            InputType.TYPE_CLASS_TEXT -> vari == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                vari == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                vari == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> vari == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }

    /** 焦点切换 → 密码框：自动 EN + 停一切采集；离开：恢复原模式。 */
    private fun applyFieldPrivacy(info: EditorInfo?) {
        SyncManager.init(this)
        val pw = isPasswordInput(info?.inputType ?: 0)
        if (pw == passwordField) return
        if (pw) {
            modeBeforePassword = imeEn
            imeEn = true // 自动切英文（不落盘：离开恢复原模式）
            passwordField = true
            SyncManager.collectionPaused = true
            SyncManager.collectionPauseReason = "password_field"
            Log.i(W24_TAG, "PRIVACY|field=password|mode=en|collection=paused|ai=off")
        } else {
            passwordField = false
            imeEn = modeBeforePassword
            SyncManager.collectionPaused = false
            SyncManager.collectionPauseReason = ""
            Log.i(
                W24_TAG,
                "PRIVACY|field=normal|mode=${if (imeEn) "en" else "cn"}|collection=resumed|ai=auto",
            )
        }
    }

    // ---- 键盘事件（W16 中文态走混输引擎；W24 英文态=直接上屏 ASCII，不过引擎） ----

    override fun onLetter(ch: Char) {
        if (imeEn) {
            // W24：英文态直接上屏（commit_code 语义，搜狗式）：不过引擎、不等部署、保留大小写
            commitText(toAscii(ch).toString())
            refresh("")
            return
        }
        if (!engineReady()) return refresh("混输引擎部署中…（首用编译码表）")
        val engine = MixedEngine.engine
        engine.onLetter(ch)
        val auto = engine.drainCommit() // 引擎自动上屏（如四码自动上屏，当前关=恒空）
        if (auto.isNotEmpty()) commitText(auto)
        syncComposing()
        currentInputConnection?.setComposingText(composing, 1)
        refresh("")
    }

    /** W24：数字/符号直输（?123 面板）。英文态=ASCII 直输；中文态=直输 + 数字键选候选（搜狗式）。 */
    override fun onDirect(ch: Char) {
        if (imeEn) {
            commitText(ch.toString())
            refresh("")
            return
        }
        if (composing.isNotEmpty()) {
            // 中文态有编码：数字键 1-9 = 点选第 n 候选（搜狗式）；其余符号先原样上屏编码
            if (ch.isDigit() && ch != '0') {
                val idx = ch - '1'
                if (idx < candidates().size) return onCandidate(idx)
            }
            val raw = composing.toString()
            if (engineReady()) MixedEngine.engine.clear()
            commitText(raw)
        }
        commitText(ch.toString())
        refresh("")
    }

    /** W24：工具栏「中/EN」切换（持久状态，落盘）。密码框强制 EN 不可切（保护账号密码）。 */
    override fun onModeToggle() {
        if (passwordField) return refresh("密码框强制英文 · 保护账号安全", error = true)
        toggleMode()
    }

    /** 模式切换（Mac switch_key: commit_code 语义：无编码=纯切换；有编码=原样上屏编码再切）。 */
    fun toggleMode(): Boolean {
        if (passwordField) return false
        if (composing.isNotEmpty()) {
            val raw = composing.toString()
            if (engineReady()) MixedEngine.engine.clear()
            commitText(raw)
        }
        imeEn = !imeEn
        val persisted = if (imeEn) "en" else "cn"
        Prefs.SettingsStore(this).imeMode = persisted // 持久：跨会话保留
        Log.i(W24_TAG, "MODE|mode=$persisted|persisted=$persisted|ok=true|source=toggle")
        refresh(if (imeEn) "英文直输 · 数字/符号同键盘" else "中文混输 · 五笔/拼音")
        return true
    }

    /** W24 调试钩子：显式设模式（en/cn），语义与切换键一致。 */
    fun setMode(en: Boolean): Boolean {
        if (passwordField) return false
        if (imeEn != en) return toggleMode()
        return true
    }

    fun mode(): String = if (imeEn) "en" else "cn"
    fun inPasswordField(): Boolean = passwordField

    /** W24 调试钩子：采集探针（走 learnAndReport 全链路；密码框应被 COLLECT_BLOCKED 拦下）。 */
    fun collectProbe() {
        learnAndReport("w24/probe", "探针上屏")
    }

    /** W24 调试钩子：「中/EN」切换键屏幕坐标（e2e 真实点按用）。 */
    fun modeChipBounds(): android.graphics.RectF? =
        if (::keyboardView.isInitialized) keyboardView.modeChipScreenBounds() else null

    override fun onDelete() {
        if (imeEn) {
            currentInputConnection?.deleteSurroundingText(1, 0)
            refresh("")
            return
        }
        if (!engineReady()) return refresh("混输引擎部署中…（首用编译码表）")
        val engine = MixedEngine.engine
        if (engine.rawInput().isNotEmpty()) {
            engine.onKey(com.mineinput.ime.engine.RimeMixedEngine.XK_BACKSPACE)
            engine.drainCommit()
            syncComposing()
            currentInputConnection?.setComposingText(composing, 1)
        } else {
            currentInputConnection?.deleteSurroundingText(1, 0)
        }
        refresh("")
    }

    override fun onEnter() {
        // W5 语义：回车=上屏原始码（不选候选）
        if (composing.isNotEmpty()) {
            val raw = composing.toString()
            if (engineReady()) MixedEngine.engine.clear()
            commitText(raw)
        } else {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
        refresh("")
    }

    override fun onSpace() {
        if (imeEn) {
            currentInputConnection?.commitText(" ", 1) // W24：英文态空格直输
            refresh("")
            return
        }
        if (!engineReady()) return refresh("混输引擎部署中…（首用编译码表）")
        val engine = MixedEngine.engine
        val raw = engine.rawInput()
        if (raw.isNotEmpty() && candidates().isNotEmpty()) {
            // 空码顶字=关（FR1 默认值）：空格不顶首选，仅上屏原始码
            engine.clear()
            commitText(raw)
        } else {
            currentInputConnection?.commitText(" ", 1)
        }
        refresh("")
    }

    override fun onSymbol() {
        // W24：?123 符号面板已落地（KeyboardView 内切换），本回调不再使用
    }

    override fun onCandidate(index: Int) {
        commitCandidate(index)
    }

    /** 点选候选上屏（返回上屏文本；w24 调试钩子断言用）。 */
    fun commitCandidate(index: Int): String {
        if (!engineReady()) return ""
        val engine = MixedEngine.engine
        val code = engine.rawInput()
        // W16：selectRimeCandidate + getRimeCommit（L1 词频/造词由 librime userdb 在此学习）
        val text = engine.commit(index)
        if (text.isEmpty()) {
            refresh("候选上屏失败", error = true)
            return ""
        }
        commitText(text)
        syncComposing()
        // W11 真实上报：candidate_pick 交互事件 + L1 词典/L2 计数学习（同意门控，静默）
        learnAndReport(code, text)
        refresh("")
        return text
    }

    // ---- PTT（FR2：按住即说 · W14 真管线） ----

    override fun onPttDown() {
        // 失败兜底前置检查：模型未装（首用下载式）/ 无麦克风权限 / 引擎未就绪 → 提示不录音
        if (!ModelManager.isInstalled(this)) {
            refresh("首次使用需下载语音模型（约 160MB）· 正在后台下载…", error = true)
            thread(name = "w14-model-autostart") {
                val ok = ModelManager.install(this) { android.util.Log.i(VoiceInput.TAG, it) }
                if (ok) AsrEngine.load(this)
            }
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            refresh("需要麦克风权限 · 请在设置页授权", error = true)
            return
        }
        if (!AsrEngine.isLoaded && !AsrEngine.load(this)) {
            refresh("语音引擎加载失败 · 请重试", error = true)
            return
        }
        val recorder = PttRecorder(
            ctx = this,
            onRolling = { text ->
                keyboardView.post {
                    keyboardView.setPttOverlay(true, text)
                }
            },
            onEvent = { msg -> android.util.Log.i(VoiceInput.TAG, msg) },
        )
        pttRecorder = recorder
        if (!recorder.start()) {
            refresh("麦克风启动失败 · 请重试", error = true)
            return
        }
        pttActive = true
        keyboardView.setPttOverlay(true, "")
        refresh("● 听写中 · 松开上屏 · 滑出/返回取消")
    }

    override fun onPttUp() {
        pttActive = false
        val recorder = pttRecorder ?: return
        refresh("转写中…")
        recorder.commit(
            this,
            object : PttRecorder.Callback {
                override fun onCommitted(text: String, finalMs: Long, numSegments: Int) {
                    keyboardView.post {
                        keyboardView.setPttOverlay(false, "")
                        refresh("松开→上屏（${finalMs}ms / $numSegments 段）")
                    }
                }

                override fun onFailed(reason: String) {
                    keyboardView.post {
                        keyboardView.setPttOverlay(false, "")
                        // 失败兜底：不瞎猜上屏，提示重说
                        refresh("未识别到内容 · 请重说（$reason）", error = true)
                    }
                }
            },
        )
    }

    override fun onPttCancel() {
        pttActive = false
        pttRecorder?.cancel()
        pttRecorder = null
        keyboardView.setPttOverlay(false, "")
        refresh("已取消 · 不上屏")
    }

    /** W14 上屏通道（W5 commit 语义：commitText + 1 光标）。 */
    fun commitVoiceText(text: String): Boolean {
        val ic = currentInputConnection ?: return false
        ic.commitText(text, 1)
        return true
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        // FR2：返回/Esc 取消听写（Android 端 = 返回键）
        if (pttActive && keyCode == KeyEvent.KEYCODE_BACK) {
            android.util.Log.i(VoiceInput.TAG, "PTT_CANCEL_REASON key=back")
            onPttCancel()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    // ---- W11：设置入口（键盘状态条「⚙ 设置」） ----

    override fun onSettings() {
        startActivity(
            Intent(this, SettingsActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    // ---- 内部 ----

    /** W5 commit 通道：上屏文本 + 清 composing。 */
    private fun commitText(text: String) {
        currentInputConnection?.commitText(text, 1)
        composing.clear()
    }

    /** W16Debug 钩子用：经 W5 commit 通道上屏（无活动输入框返回 false）。 */
    fun commitEngineText(text: String): Boolean {
        val ic = currentInputConnection ?: return false
        ic.commitText(text, 1)
        return true
    }

    private fun engineReady(): Boolean = MixedEngine.engine.isStarted

    /** composing 显示 = 引擎 rawInput（preedit）。 */
    private fun syncComposing() {
        composing.setLength(0)
        if (engineReady()) composing.append(MixedEngine.engine.rawInput())
    }

    /** W24：英文态标点归一到 ASCII（账号密码场景要 ASCII 符号）。 */
    private fun toAscii(ch: Char): Char = when (ch) {
        '，' -> ','
        '。' -> '.'
        '？' -> '?'
        '！' -> '!'
        '：' -> ':'
        '；' -> ';'
        '（' -> '('
        '）' -> ')'
        else -> ch
    }

    /** L1 词典 / L2 习惯计数 + 事件上报（全部受同意/熔断门控；撤回同意后不再上报）。 */
    private fun learnAndReport(code: String, picked: String) {
        SyncManager.init(this)
        if (passwordField) {
            // W24：密码框 → 一切采集关死（不写 userdb、不上报、不调 AI/云端）
            Log.i(W24_TAG, "COLLECT_BLOCKED|reason=password_field|kind=candidate_pick")
            return
        }
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
     * 候选栏真数据（W16）：librime ping_wubi_mixed 引擎候选 —— 五笔86 形码优先 +
     * 拼音并联兜底（无五笔命中前移）+ z 反查注释（comment）。
     * 展示映射：comment 非空 →「text · comment」（如 你 · wq wqiy）。
     */
    private fun candidates(): List<String> {
        if (!engineReady()) return emptyList()
        return MixedEngine.engine.candidates(0, 8).map { display(it) }
    }

    private fun display(c: EngineCandidate): String =
        if (c.comment.isNotBlank()) "${c.text} · ${c.comment}" else c.text

    private fun refresh(status: String, error: Boolean = false) {
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
                imeEn -> "EN 直输 · 字母/数字/符号直接上屏"
                settings.fuseBlown -> "熔断中 · 采集与上报已停止"
                !consent.any -> "未同意采集 · 不上报"
                else -> "就绪"
            }
            // W24：AI 智能候选组标记（demoAiCount=演示位；真实 AI 来源接入=TODO 卡）
            val aiFlags = cands.indices.map { it < demoAiCount }
            keyboardView.updateState(composing.toString(), cands, statusText, bits, error, imeEn, aiFlags)
        }
    }
}
