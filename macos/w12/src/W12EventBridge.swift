import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

/// W7×W9 接线（任务书 (b)）：W7 的输入会话 / 语音会话 / 候选选择事件
/// 上报 W9 InteractionStore（**启用入库 API**：C0Collector.record* 系列）。
///
/// Squirrel 侧调用点（macos/w12/src/W12SquirrelGlue.swift）只经过本桥，
/// 不直接触碰 store；本桥是唯一入口，脚本化实测走同一 API（同一语义、同一落库路径）。
///
/// 隐私红线沿用 W9：上屏文本留存默认关（text_out 空）、安全输入拒收、
/// 黑名单拒收、熔断立即停（store.insert 兜底再拒一次）。
public final class W12EventBridge {
    public static let shared = W12EventBridge()

    public let store: InteractionStore
    public let collector: C0Collector
    public let breaker: CircuitBreaker

    /// 交互日志路径：MINE_INTERACTION_DB env > Info.plist W12InteractionDB
    /// > W9 默认路径（~/Library/Application Support/mine-input/interaction.db）。
    public static func defaultDBPath(bundle: Bundle = .main) -> String {
        if let env = ProcessInfo.processInfo.environment["MINE_INTERACTION_DB"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        if let p = bundle.object(forInfoDictionaryKey: "W12InteractionDB") as? String {
            return (p as NSString).expandingTildeInPath
        }
        let base = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true).first ?? "/tmp"
        return (base as NSString).appendingPathComponent("mine-input/interaction.db")
    }

    public init(path: String? = nil) {
        let dbPath = path ?? Self.defaultDBPath()
        // store 打开失败不应杀 IME 进程：退化为内存临时库（采集降级，不影响输入）。
        let opened = try? InteractionStore(path: dbPath)
        let s = (try? InteractionStore(path: NSTemporaryDirectory() + "w12-fallback.db"))!
        self.store = opened ?? s
        self.breaker = CircuitBreaker(store: store)
        self.collector = C0Collector(store: store, breaker: breaker)
    }

    /// W7 输入会话（kind=key_session）：打字/上屏会话。
    /// textIn=输入串（C0 允许）；textOut=上屏文本（留存默认关 → 落库为空）。
    @discardableResult
    public func reportKeySession(
        textIn: String, textOut: String, cadence: Double? = nil,
        appId: String? = nil, secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        collector.recordKeySession(
            textIn: textIn, textOut: textOut, keystrokeCadence: cadence,
            appId: appId, secureInput: secureInput)
    }

    /// W7 语音会话（kind=voice_session）：PTT 松开 → W2 管线 → 上屏。
    /// asrDigest=C1 摘要（默认 nil；由 W12C1Collector 计算，仅摘要/长度）。
    @discardableResult
    public func reportVoiceSession(
        textIn: String, textOut: String, asrDigest: String? = nil,
        appId: String? = nil, secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        collector.recordVoiceSession(
            textIn: textIn, textOut: textOut, asrDigest: asrDigest,
            appId: appId, secureInput: secureInput)
    }

    /// W7 候选选择（kind=candidate_pick）。
    @discardableResult
    public func reportCandidatePick(
        textIn: String, textOut: String, cadence: Double? = nil,
        appId: String? = nil, secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        collector.recordCandidatePick(
            textIn: textIn, textOut: textOut, keystrokeCadence: cadence,
            appId: appId, secureInput: secureInput)
    }

    /// 提词浮层采纳反馈（kind=suggestion_feedback，taken=1 表示 Tab/点按采纳）。
    @discardableResult
    public func reportSuggestionFeedback(
        shown: Int, taken: Int, textIn: String, adoptedText: String, appId: String? = nil
    ) -> InteractionStore.InsertResult {
        collector.recordSuggestionFeedback(
            shown: shown, taken: taken, textIn: textIn,
            adoptedText: adoptedText, appId: appId)
    }

    /// C1 样本入库（kind=key_session（OCR）/ voice_session（ASR））：
    /// **只落 ocr_digest/asr_digest（摘要+长度），绝不落原图/全文**。
    @discardableResult
    public func reportC1Sample(
        kind: EventKind, ocrDigest: String? = nil, asrDigest: String? = nil,
        appId: String? = nil, secureInput: Bool = false
    ) -> InteractionStore.InsertResult {
        collector.recordC1Sample(
            kind: kind, ocrDigest: ocrDigest, asrDigest: asrDigest,
            appId: appId, secureInput: secureInput)
    }
}
