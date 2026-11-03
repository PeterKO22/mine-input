import CoreGraphics
import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

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
    /// - Parameter pttActive: PTT 语音会话进行中。
    public struct TriggerDecision: Equatable {
        public let shouldCapture: Bool
        public let reason: String
    }

    public static func decideTrigger(
        now: TimeInterval,
        lastCaptureAt: TimeInterval?,
        lastKeyAt: TimeInterval?,
        pttActive: Bool,
        debounce: TimeInterval = 2.0
    ) -> TriggerDecision {
        // 仅输入时触发：PTT 期间，或按键触发窗内（距最近按键 ≤ 防抖窗）
        let inInputWindow = pttActive
            || (lastKeyAt.map { now - $0 <= debounce } ?? false)
        guard inInputWindow else {
            return TriggerDecision(shouldCapture: false, reason: "not in input window (PTT 期间/按键触发窗之外)")
        }
        if let last = lastCaptureAt, now - last < debounce {
            return TriggerDecision(shouldCapture: false, reason: "debounced (\(String(format: "%.1f", now - last))s < \(debounce)s)")
        }
        return TriggerDecision(shouldCapture: true, reason: "input trigger (ptt=\(pttActive))")
    }

    public static let shared = W12C1Collector()

    public let bridge: W12EventBridge
    public var settings: W12Settings
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

    // ------------------------------------------------------------ 触发

    /// 按键触发（Squirrel handle() 每次 keyDown 调用）：防抖 2s，触发一轮屏幕采集。
    /// secureInput 由 IME 侧传入（IsSecureEventInputEnabled()，密码框自动停）。
    public func noteKeystroke(
        appId: String?, secureInput: Bool,
        completion: ((Outcome) -> Void)? = nil
    ) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        lastKeyAt = now
        let decision = Self.decideTrigger(
            now: now, lastCaptureAt: lastCaptureAt, lastKeyAt: now,
            pttActive: pttActive, debounce: settings.debounceSeconds)
        if decision.shouldCapture { lastCaptureAt = now }
        lock.unlock()
        guard decision.shouldCapture else {
            completion?(.skipped(decision.reason))
            return
        }
        guard isC1Enabled else {
            completion?(.refused("C1 collection disabled (default off; 需显式开启)"))
            return
        }
        guard settings.c1Screen else {
            completion?(.skipped("c1 screen sub-switch off"))
            return
        }
        Task {
            let outcome = await self.captureAndIngest(
                source: .screen, kind: .keySession,
                appId: appId, secureInput: secureInput)
            completion?(outcome)
        }
    }

    /// PTT 语音会话窗口（W7PttController.start/stop 调用）。
    public func notePttStart() {
        lock.lock(); pttActive = true; lock.unlock()
    }

    public func notePttEnd() {
        lock.lock(); pttActive = false; lock.unlock()
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
        markCaptured()

        let cgImage: CGImage
        do {
            cgImage = try await W12ScreenCapture.captureCGImage(source)
        } catch {
            return .refused("capture failed: \(error)")
        }
        let ocr: W12OCR.Result
        do {
            ocr = try W12OCR.recognize(cgImage: cgImage)
        } catch {
            return .refused("ocr failed: \(error)")
        }
        // OCR 全文只在内存到此为止（摘要已算出）；入库前再查熔断（立即停）。
        if bridge.breaker.isTripped {
            return .refused("circuit breaker tripped: collection stopped")
        }
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
        lastCaptureAt = Date().timeIntervalSince1970
        lock.unlock()
    }
}
