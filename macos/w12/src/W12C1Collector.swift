import CoreGraphics
import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

/// W27 统一输入事件（按键/语音快捷键 → 读屏的触发源）。
public enum W12InputTrigger: Equatable {
    /// 按键事件（SquirrelInputController.handle() keyDown）。
    case keystroke
    /// PTT 语音触发（右⌘按住 / ⌃⌥M 兜底键按下）：开语音触发窗 + 即时读屏。
    case pttStart
    /// PTT 结束（松开上屏/取消）：收口触发窗。
    case pttEnd
}

/// W12 C1 采集编排（任务书 (a)）：
///
/// 触发（**仅输入时**）：PTT 期间 + 按键触发窗（用户正在打字），防抖 2s
///（输入触发窗内至多一轮采集，NFR5「采集防抖不耗电」）。
/// 产物入库（InteractionStore）：
///   - 屏幕快照（ScreenCaptureKit）→ Vision OCR → `ocr_digest`（**仅摘要/长度，
///     不落原图、不落 OCR 全文**）；
///   - 系统音频环回/麦克风 → W2 管线（voice/mic/ptt_daemon）→ `asr_digest`（同上）。
///
/// 硬门禁（任一命中即停，顺序即优先级）：
///   1. C1 显式开关未开（默认关，W12Privacy.enableC1(explicitConfirm:)）→ 拒；
///   2. 熔断开启（CircuitBreaker 全局开关）→ **立即停**（触发前查 + 入库前再查，
///      store.insert 兜底拒）；
///   3. 安全输入（密码框/支付，IsSecureEventInputEnabled / 调用方标记）→ 自动停不可关；
///   4. 敏感应用黑名单 → 跳过（不采集不入库）。
public final class W12C1Collector {
    public enum Outcome: Equatable {
        case ingested(id: Int64, digest: String)
        case refused(String)
        case skipped(String)
    }

    /// 触发判定（纯函数，可单测）：防抖 2s + 仅输入时触发。
    /// - Parameter lastCaptureAt: 上一轮采集时刻（秒）；nil = 从未采集；
    /// - Parameter lastKeyAt: 最近一次按键时刻（按键触发窗）；
    /// - Parameter pttActive: PTT 语音会话进行中；
    /// - Parameter immediate: W27-fix——`.pttStart` 显式动作（「按键（包括语音快捷键）
    ///   即读取屏幕」）**绕防抖**：防抖窗内仍即时采集；防抖只合并按键流（.keystroke）。
    public struct TriggerDecision: Equatable {
        public let shouldCapture: Bool
        public let reason: String
    }

    public static func decideTrigger(
        now: TimeInterval,
        lastCaptureAt: TimeInterval?,
        lastKeyAt: TimeInterval?,
        pttActive: Bool,
        debounce: TimeInterval = 2.0,
        immediate: Bool = false
    ) -> TriggerDecision {
        // 仅输入时触发：PTT 期间，或按键触发窗内（距最近按键 ≤ 防抖窗）
        let inInputWindow = pttActive
            || (lastKeyAt.map { now - $0 <= debounce } ?? false)
        guard inInputWindow else {
            return TriggerDecision(shouldCapture: false, reason: "not in input window (PTT 期间/按键触发窗之外)")
        }
        // W27-fix：immediate（.pttStart）绕防抖——PTT 键是用户显式动作，防抖窗内仍即时读屏；
        // 防抖只合并按键流，不吞显式 PTT 触发（原实现 pttStart 与 keystroke 同走防抖判定，
        // 防抖窗内会被 debounced，与「即时读屏」文档语义不符——产品缺陷实锤修复）。
        if !immediate, let last = lastCaptureAt, now - last < debounce {
            return TriggerDecision(shouldCapture: false, reason: "debounced (\(String(format: "%.1f", now - last))s < \(debounce)s)")
        }
        let suffix = immediate ? ", immediate: bypass debounce" : ""
        return TriggerDecision(shouldCapture: true, reason: "input trigger (ptt=\(pttActive)\(suffix))")
    }

    public static let shared = W12C1Collector()

    public let bridge: W12EventBridge
    public var settings: W12Settings
    /// W27 屏幕文本上下文存储（OCR 全文 → 截断摘要入环；默认进程内单例，测试可注入）。
    public var screenContext: ScreenTextContext = .shared
    /// W27 注入探针/测试用：非 nil 时采集走该源（文件源=等价一帧截屏，同一 OCR→摘要→
    /// 入库链路）；生产恒 nil（走 .screen ScreenCaptureKit）。
    public var captureSourceOverride: W12CaptureSource? = nil
    /// W32 注入探针/测试用：非 nil 时屏幕帧取自该闭包（免真实 ScreenCaptureKit/TCC）；
    /// 生产恒 nil（走 W12ScreenCapture.captureCGImage）。
    public var captureImageOverride: ((W12CaptureSource) async throws -> CGImage)? = nil
    /// W32 录屏授权探针/请求注入（授权状态可 mock；生产 = CGPreflight/CGRequest）。
    /// 硬规则：采集路径只 `preflight` 探活；`requestAccess` 唯一发起点 = ⌥M 开关打开动作。
    public var screenAccess: W12ScreenAccess = .live()
    /// W27-fix 防抖时钟注入（默认 `Date()` 墙钟，生产行为不变）：探针/单测传伪时间，
    /// 消除「用真实 sleep 模拟事件间隔」撞防抖窗的时序竞态（w27-e2e 确定性化的落点）。
    public var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
    private let lock = NSLock()
    private var lastCaptureAt: TimeInterval? = nil
    private var lastKeyAt: TimeInterval? = nil
    private var pttActive = false

    public init(bridge: W12EventBridge = .shared, settings: W12Settings = .load()) {
        self.bridge = bridge
        self.settings = settings
    }

    /// C1 总开关（显式）：Info.plist W12C1Enabled 或运行时 meta 显式开启。
    public var isC1Enabled: Bool {
        settings.c1Enabled || W12Privacy.isC1ExplicitlyEnabled(store: bridge.store)
    }

    /// W32 读屏（屏幕上下文）有效开关：⌥M 显式开关（持久 meta `c1_screen`，默认关）
    /// 或 dev 直通（W12C1Screen/MINE_W12_*，探针用）。**默认 OFF**——不开启绝不读屏。
    public var isScreenEnabled: Bool {
        settings.c1Screen || W12Privacy.isC1ScreenEnabled(store: bridge.store)
    }

    // ------------------------------------------------------------ 触发

    /// W27 统一输入事件入口（任务书 (1)）：**SquirrelInputController 按键事件**与
    /// **PTT 语音触发（右⌘按住 / ⌃⌥M 兜底键）**都走本入口。
    ///
    /// 防抖与合并：防抖 1–2s（`settings.debounceSeconds`，默认 2s）；同一输入会话
    /// （按键/PTT 触发间隙 ≤ 防抖窗的连续事件段）内的多次触发**合并为一轮采集**
    /// ——防抖窗内至多一轮（NFR5「采集防抖不耗电」），窗口外的持续输入每窗最多一轮。
    ///
    /// 语义：
    ///   - `.keystroke`：按键触发窗 + 防抖 → 屏幕快照→Vision OCR→上下文存储；
    ///   - `.pttStart`：PTT 语音触发（右⌘按下 / ⌃⌥M）——打开语音触发窗（pttActive）
    ///     **并**即时触发一轮屏幕采集（「按键（包括语音快捷键）即读取屏幕」）；
    ///     **绕防抖**（W27-fix）：PTT 键为显式动作，防抖窗内仍即时读屏（原实现误走防抖
    ///     判定，窗内被 debounced——产品缺陷已修，防抖只合并按键流）；
    ///   - `.pttEnd`：PTT 结束收口触发窗（不采集）。
    ///
    /// 门禁照旧：C1 显式开关（默认关）/ 密码框（secureInput）零采集 / 熔断立即停 /
    /// 黑名单跳过；**W32 读屏门禁**：屏幕上下文默认 OFF（⌥M 显式开关才读屏），
    /// 开关开但未授权 → 跳过读屏（只 CGPreflight 探活，绝不自动 CGRequest）。
    public func onInputEvent(
        _ trigger: W12InputTrigger,
        appId: String?, secureInput: Bool,
        completion: ((Outcome) -> Void)? = nil
    ) {
        switch trigger {
        case .pttEnd:
            lock.lock(); pttActive = false; lock.unlock()
            completion?(.skipped("ptt end (input window closed)"))
            return
        case .pttStart:
            lock.lock(); pttActive = true; lock.unlock()
        case .keystroke:
            break
        }
        // C1 总开关关（默认关）→ 直接拒：零采集零副作用，不触碰防抖状态
        //（开启 C1 后的首个按键立即可采，不被关着时的按键挤占防抖窗）。
        guard isC1Enabled else {
            completion?(.refused("C1 collection disabled (default off; 需显式开启)"))
            return
        }
        // W32：读屏开关关（屏幕上下文默认 OFF）→ 跳过读屏，零权限交互零防抖状态。
        guard isScreenEnabled else {
            completion?(.skipped(W12ScreenGate.skipSwitchOffReason))
            return
        }
        let now = clock()
        lock.lock()
        lastKeyAt = now
        let decision = Self.decideTrigger(
            now: now, lastCaptureAt: lastCaptureAt, lastKeyAt: now,
            pttActive: pttActive, debounce: settings.debounceSeconds,
            immediate: trigger == .pttStart)   // W27-fix：pttStart 绕防抖（即时读屏）
        if decision.shouldCapture { lastCaptureAt = now }
        lock.unlock()
        guard decision.shouldCapture else {
            completion?(.skipped(decision.reason))
            return
        }
        Task {
            let outcome = await self.captureAndIngest(
                source: self.captureSourceOverride ?? .screen, kind: .keySession,
                appId: appId, secureInput: secureInput)
            completion?(outcome)
        }
    }

    /// 按键触发（Squirrel handle() 每次 keyDown 调用）：W27 起统一转发 `onInputEvent`。
    /// secureInput 由 IME 侧传入（IsSecureEventInputEnabled()，密码框自动停）。
    public func noteKeystroke(
        appId: String?, secureInput: Bool,
        completion: ((Outcome) -> Void)? = nil
    ) {
        onInputEvent(.keystroke, appId: appId, secureInput: secureInput, completion: completion)
    }

    /// PTT 语音会话窗口（W7PttController.start/stop 调用）。
    public func notePttStart() {
        onInputEvent(.pttStart, appId: nil, secureInput: false)
    }

    public func notePttEnd() {
        onInputEvent(.pttEnd, appId: nil, secureInput: false)
    }

    /// PTT 转写落定（W2 管线输出）→ **W7×W9 接线：语音会话事件一律上报**
    ///（C1 关也上报；C1 开且过门禁时附 asr_digest 摘要，仅摘要/长度，全文即弃）。
    @discardableResult
    public func notePttTranscript(
        _ transcript: String, textIn: String = "", appId: String?, secureInput: Bool
    ) -> Outcome {
        var digest: String? = nil
        if settings.c1Audio, isC1Enabled, !transcript.isEmpty,
           case .ingested = precheck(appId: appId, secureInput: secureInput) {
            digest = W12Digest.summary(transcript)
        }
        let r = bridge.reportVoiceSession(
            textIn: textIn, textOut: transcript, asrDigest: digest,
            appId: appId, secureInput: secureInput)
        return finish(r, digest: digest ?? "")
    }

    // ------------------------------------------------------------ 采集 → OCR → 入库

    /// 一轮 C1 采集（屏幕快照/文件源）→ OCR → ocr_digest 入库。
    /// 门禁在触发前与入库前各查一次（熔断立即停）。
    public func captureAndIngest(
        source: W12CaptureSource, kind: EventKind = .keySession,
        appId: String?, secureInput: Bool
    ) async -> Outcome {
        guard isC1Enabled else {
            return .refused("C1 collection disabled (default off; 需显式开启)")
        }
        if case .refused(let reason) = precheck(appId: appId, secureInput: secureInput) {
            return .refused(reason)
        }
        if case .skipped(let reason) = precheck(appId: appId, secureInput: secureInput) {
            return .skipped(reason)
        }
        // W32 读屏门禁（仅真实屏幕源；文件源 = 探针等价帧，不涉 TCC）：
        // 开关关（默认）/ 未授权 → 跳过读屏；未授权**绝不**自动发起授权请求（只探活）。
        if case .screen = source {
            switch W12ScreenGate.decide(
                screenSwitchOn: isScreenEnabled,
                screenAuthorized: screenAccess.preflight()) {
            case .readScreen:
                break
            case .skipSwitchOff:
                return .skipped(W12ScreenGate.skipSwitchOffReason)
            case .skipNotAuthorized:
                return .skipped(W12ScreenGate.skipNotAuthorizedReason)
            }
        }
        markCaptured()

        let cgImage: CGImage
        do {
            cgImage = try await (captureImageOverride ?? W12ScreenCapture.captureCGImage)(source)
        } catch {
            return .refused("capture failed: \(error)")
        }
        let ocr: W12OCR.Result
        do {
            ocr = try W12OCR.recognize(cgImage: cgImage)
        } catch {
            return .refused("ocr failed: \(error)")
        }
        // OCR 全文只在内存参与摘要/上下文截断，随即丢弃（不落原图、不落全文入库）；
        // 入库前再查熔断（立即停）——熔断拒收时也不入屏幕上下文环。
        if bridge.breaker.isTripped {
            return .refused("circuit breaker tripped: collection stopped")
        }
        // W27：OCR 文本摘要化进屏幕文本上下文存储（ScreenTextContext 环，仅内存），
        // 供推荐链（SuggestContext.screenText）与记忆层情境（situation.screen_text）。
        screenContext.noteOCR(ocr.text)
        let r = bridge.reportC1Sample(
            kind: kind, ocrDigest: ocr.digestSummary,
            appId: appId, secureInput: secureInput)
        return finish(r, digest: ocr.digestSummary)
    }

    /// ASR 链路：音频（16k mono PCM16）→ W2 管线 → asr_digest 入库。
    public func transcribeAndIngest(
        pcm16: Data, client: W12AsrClient,
        appId: String?, secureInput: Bool
    ) -> Outcome {
        guard settings.c1Audio else { return .refused("C1 audio sub-switch off") }
        guard isC1Enabled else {
            return .refused("C1 collection disabled (default off; 需显式开启)")
        }
        if case .refused(let reason) = precheck(appId: appId, secureInput: secureInput) {
            return .refused(reason)
        }
        if case .skipped(let reason) = precheck(appId: appId, secureInput: secureInput) {
            return .skipped(reason)
        }
        let result = client.transcribe(pcm16)
        if let err = result.error { return .refused("asr failed: \(err)") }
        if bridge.breaker.isTripped {
            return .refused("circuit breaker tripped: collection stopped")
        }
        let digest = W12Digest.summary(result.text)
        let r = bridge.reportC1Sample(
            kind: .voiceSession, asrDigest: digest,
            appId: appId, secureInput: secureInput)
        return finish(r, digest: digest)
    }

    // ------------------------------------------------------------ 门禁

    /// 采集前门禁（熔断立即停 / 密码框自动停 / 黑名单跳过）。
    public func precheck(appId: String?, secureInput: Bool) -> Outcome {
        if bridge.breaker.isTripped {
            return .refused("circuit breaker tripped: collection stopped")
        }
        if secureInput {
            return .refused("secure input: auto-paused (cannot be disabled)")
        }
        let id = appId ?? C0Collector.frontmostApp().bundleId
        if bridge.collector.isBlacklisted(id) {
            return .skipped("blacklisted app: \(id)")
        }
        return .ingested(id: -1, digest: "")
    }

    private func finish(_ r: InteractionStore.InsertResult, digest: String) -> Outcome {
        switch r {
        case .stored(let id):
            return .ingested(id: id, digest: digest)
        case .refused(let err):
            return .refused("\(err)")
        }
    }

    /// 记录采集时刻（防抖基准；同步小函数，避免 async 上下文用锁）。
    private func markCaptured() {
        lock.lock()
        lastCaptureAt = clock()   // W27-fix：走注入时钟（默认 Date()），与触发判定同一时间轴
        lock.unlock()
    }

    // ------------------------------------------------------------ 推荐链上下文

    /// 构造推荐链请求上下文（智能候选 / ⌥Esc 提词浮层共用的 SuggestContext 请求链）：
    /// `screenText` = 近期 OCR 摘要（ScreenTextContext 截断拼接），**仅当**
    /// C1 显式开启、读屏开关开（W32 屏幕上下文默认 OFF）、未熔断、非密码框
    /// （secureInput）时填充；任一不满足即空串（默认空串，屏幕文本绝不上报第三方）。
    public func makeSuggestContext(
        beforeCursor: String, appId: String = "",
        fromVoice: Bool = false, secureInput: Bool = false
    ) -> SuggestContext {
        let screenText: String
        if isC1Enabled, isScreenEnabled, !bridge.breaker.isTripped, !secureInput {
            screenText = screenContext.recentSummary()
        } else {
            screenText = ""
        }
        return SuggestContext(
            beforeCursor: beforeCursor, appId: appId,
            fromVoice: fromVoice, screenText: screenText)
    }
}
