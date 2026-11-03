import AppKit
import Foundation

/// C0 采集器（FR4 / 技术方案 §8.2，隐私红线）：
/// - C0 仅：输入框上下文（text_in/text_out）、应用名（app_id，NSWorkspace）、
///   输入历史（事件流本身）；C1 字段（ocr_digest/asr_digest）默认 NULL，本 MVP 不采集；
/// - **剪贴板采集默认关**，必须显式开关（enableClipboardCollection(explicitConfirm:)）
///   才允许取样，且取样只记摘要与长度，**绝不记内容**；
/// - 安全输入（密码框/支付）自动暂停不可关：secureInput=true 时一律拒收；
/// - 敏感应用黑名单命中即拒收；
/// - 熔断开启时一切入库立即停（日志保留不新增）。
///
/// 输入会话事件入库 API（`record*` 系列）为 W7 macos 集成的上报入口：
/// W7 在按键/上屏/采纳回调里调用这些方法即可落交互日志（本地 SQLite）。
public final class C0Collector {
    public struct AppInfo: Equatable, CustomStringConvertible {
        public let bundleId: String
        public let localizedName: String
        public var description: String { "\(localizedName) (\(bundleId))" }
    }

    /// 敏感应用黑名单（FR4）：命中即不采集。bundle id 前缀匹配，可由上层扩展。
    public static let defaultBlacklist: [String] = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword",
        "com.1password",
        "com.bitwarden.desktop",
        "com.lastpass",
        "org.keepassxc",
    ]

    private let store: InteractionStore
    private let breaker: CircuitBreaker
    public let deviceId: String
    public private(set) var blacklist: Set<String>

    /// 剪贴板采集开关——**默认关（隐私红线）**。
    public private(set) var clipboardCollectionEnabled = false

    /// 上屏文本留存（L3，默认关）：关时 text_out 只记长度不留全文。
    public var commitTextRetention = false

    public init(
        store: InteractionStore,
        breaker: CircuitBreaker,
        deviceId: String? = nil,
        blacklist: [String] = C0Collector.defaultBlacklist
    ) {
        self.store = store
        self.breaker = breaker
        self.deviceId = store.deviceId(override: deviceId)
        self.blacklist = Set(blacklist.map { $0.lowercased() })
    }

    // ------------------------------------------------------------ C0 应用名

    /// 当前 frontmost 应用（NSWorkspace）——C0 级「当前应用名」。
    public static func frontmostApp() -> AppInfo {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return AppInfo(bundleId: "", localizedName: "(unknown)")
        }
        return AppInfo(
            bundleId: app.bundleIdentifier ?? "",
            localizedName: app.localizedName ?? "(unnamed)")
    }

    public func isBlacklisted(_ appId: String) -> Bool {
        let id = appId.lowercased()
        return blacklist.contains { id.hasPrefix($0.lowercased()) }
    }

    // ------------------------------------------------------------ 入库 API（供 W7）

    /// 打字/输入会话事件入库（kind=key_session）。
    /// - Parameter secureInput: 密码框/支付场景 → 自动暂停，拒收且不可关。
    @discardableResult
    public func recordKeySession(
        textIn: String = "",
        textOut: String = "",
        keystrokeCadence: Double? = nil,
        suggestionShown: Int? = nil,
        suggestionTaken: Int? = nil,
        appId: String? = nil,
        secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        submit(
            kind: .keySession, textIn: textIn, textOut: textOut,
            keystrokeCadence: keystrokeCadence,
            suggestionShown: suggestionShown, suggestionTaken: suggestionTaken,
            appId: appId, secureInput: secureInput)
    }

    /// 语音会话事件入库（kind=voice_session）。
    @discardableResult
    public func recordVoiceSession(
        textIn: String = "",
        textOut: String = "",
        asrDigest: String? = nil, // C1 摘要，默认 nil
        suggestionShown: Int? = nil,
        suggestionTaken: Int? = nil,
        appId: String? = nil,
        secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        submit(
            kind: .voiceSession, textIn: textIn, textOut: textOut,
            asrDigest: asrDigest,
            suggestionShown: suggestionShown, suggestionTaken: suggestionTaken,
            appId: appId, secureInput: secureInput)
    }

    /// 候选采纳事件（kind=candidate_pick）。
    @discardableResult
    public func recordCandidatePick(
        textIn: String = "",
        textOut: String = "",
        keystrokeCadence: Double? = nil,
        appId: String? = nil,
        secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        submit(
            kind: .candidatePick, textIn: textIn, textOut: textOut,
            keystrokeCadence: keystrokeCadence,
            appId: appId, secureInput: secureInput)
    }

    /// 提词器建议反馈（kind=suggestion_feedback；suggestion_taken=1 表示 Tab/数字/点按采纳）。
    @discardableResult
    public func recordSuggestionFeedback(
        shown: Int,
        taken: Int,
        textIn: String = "",
        adoptedText: String = "",
        appId: String? = nil
    ) -> InteractionStore.InsertResult {
        submit(
            kind: .suggestionFeedback, textIn: textIn,
            textOut: commitTextRetention ? adoptedText : "",
            suggestionShown: shown, suggestionTaken: taken,
            appId: appId, secureInput: false)
    }

    /// C1 上下文样本入库（W12 扩展，kind=key_session（OCR）/ voice_session（ASR））：
    /// **只落 ocr_digest/asr_digest（摘要+长度），绝不落原图/OCR 全文/ASR 全文**。
    /// 门禁与其余 record* 一致：熔断立即停、安全输入自动停、黑名单拒收。
    @discardableResult
    public func recordC1Sample(
        kind: EventKind,
        ocrDigest: String? = nil,
        asrDigest: String? = nil,
        appId: String? = nil,
        secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        submit(
            kind: kind, textIn: "", textOut: "",
            ocrDigest: ocrDigest, asrDigest: asrDigest,
            appId: appId, secureInput: secureInput)
    }

    // ------------------------------------------------------------ 剪贴板（默认关）

    /// 显式开启剪贴板采集（隐私红线：必须显式确认，默认关）。
    public func enableClipboardCollection(explicitConfirm: Bool) -> Bool {
        guard explicitConfirm else { return false }
        clipboardCollectionEnabled = true
        return true
    }

    public func disableClipboardCollection() {
        clipboardCollectionEnabled = false
    }

    /// 剪贴板取样：开关未显式开启时拒绝；开启后也**只记摘要与长度，不记内容**。
    /// 采集状态：熔断/黑名单同样生效。
    public func recordClipboardSample(appId: String? = nil) -> InteractionStore.InsertResult {
        guard clipboardCollectionEnabled else {
            return .refused(.execFailed("clipboard collection disabled (default off)"))
        }
        guard !breaker.isTripped else { return .refused(.tripped) }
        let id = appId ?? Self.frontmostApp().bundleId
        guard !isBlacklisted(id) else {
            return .refused(.execFailed("blacklisted app: \(id)"))
        }
        let pb = NSPasteboard.general
        let content = pb.string(forType: .string) ?? ""
        let digest = Self.sha256Hex(content).prefix(16)
        return submit(
            kind: .keySession,
            textIn: "",
            textOut: "",
            ocrDigest: nil,
            asrDigest: nil,
            extraNote: "clipboard_digest=\(digest) clipboard_len=\(content.count)",
            appId: id,
            secureInput: false)
    }

    // ------------------------------------------------------------ 内部

    private func submit(
        kind: EventKind,
        textIn: String,
        textOut: String,
        ocrDigest: String? = nil,
        asrDigest: String? = nil,
        keystrokeCadence: Double? = nil,
        suggestionShown: Int? = nil,
        suggestionTaken: Int? = nil,
        extraNote: String? = nil,
        appId: String?,
        secureInput: Bool
    ) -> InteractionStore.InsertResult {
        // 熔断：一切采集立即停（先查早停，store.insert 再兜底一次）。
        if breaker.isTripped { return .refused(.tripped) }
        if secureInput { return .refused(.secureInputPaused) }
        let id = appId ?? Self.frontmostApp().bundleId
        if isBlacklisted(id) {
            return .refused(.execFailed("blacklisted app: \(id)"))
        }
        var ev = InteractionEvent(
            deviceId: deviceId,
            appId: id,
            kind: kind,
            textIn: textIn,
            textOut: commitTextRetention ? textOut : "",
            ocrDigest: ocrDigest,
            asrDigest: asrDigest,
            keystrokeCadence: keystrokeCadence,
            suggestionShown: suggestionShown,
            suggestionTaken: suggestionTaken)
        if let note = extraNote {
            // 非全文、结构化补充（如剪贴板摘要/长度）挂 text_in 末尾的字段串。
            ev.textIn = textIn.isEmpty ? note : "\(textIn) | \(note)"
        }
        return store.insert(ev, secureInput: secureInput)
    }

    static func sha256Hex(_ s: String) -> String {
        // 仅用于剪贴板摘要；避免引 CryptoKit 之外的依赖，用 CommonCrypto 风格不可用时
        // 退化为 FNV-1a 64 位摘要（摘要用途：对比变化，不用于安全签名）。
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", h)
    }
}
