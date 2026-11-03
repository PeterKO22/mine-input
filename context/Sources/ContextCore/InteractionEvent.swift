import Foundation

/// 交互事件类型 —— 对齐 Hub `/v1/ingest` 的 `EventKind`
/// （hub/app/main.py：`key_session | voice_session | candidate_pick | suggestion_feedback`），
/// 即技术方案 v0.4 §8.2「交互日志：时间索引事件流」的事件种类。
public enum EventKind: String, Codable, CaseIterable {
    case keySession = "key_session"
    case voiceSession = "voice_session"
    case candidatePick = "candidate_pick"
    case suggestionFeedback = "suggestion_feedback"
}

/// 交互日志事件 —— 表结构/字段对齐技术方案 v0.4 §8.2 InteractionEvent
/// （`ts / device_id / app_id / kind / text_in / text_out / ocr_digest? /
///   asr_digest? / keystroke_cadence / suggestion_shown / suggestion_taken`），
/// 与 hub/app/main.py `IngestIn` 逐字段同名同义（契约即协议，W4-REPORT §1）。
///
/// 与 `ai/spi/ai_assist.h` `InteractionEvent` 的映射（见 W9-REPORT §2）：
///   timestamp_ms ↔ ts；type(kCommit/kSuggestionShown/…) ↔ kind + fields 语义；
///   text ↔ text_in/text_out；fields ↔ 其余结构化列。
///
/// 隐私红线（FR4 / D9/D10）：C0 级仅输入框上下文/应用名/输入历史；
/// ocr_digest/asr_digest 为 C1（默认 NULL）；上屏文本留存（text_out）默认关，
/// 由上层开关决定是否填写；剪贴板采集默认关（见 C0Collector）。
public struct InteractionEvent: Codable, Equatable {
    /// Unix 毫秒（时间索引，§8.2）
    public var ts: Int64
    public var deviceId: String
    public var appId: String
    public var kind: EventKind
    public var textIn: String
    public var textOut: String
    /// C1（默认关）：屏幕 OCR 摘要（只留摘要不留全文）
    public var ocrDigest: String?
    /// C1（默认关）：系统音频 ASR 摘要
    public var asrDigest: String?
    public var keystrokeCadence: Double?
    public var suggestionShown: Int?
    public var suggestionTaken: Int?

    public init(
        ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        deviceId: String,
        appId: String = "",
        kind: EventKind,
        textIn: String = "",
        textOut: String = "",
        ocrDigest: String? = nil,
        asrDigest: String? = nil,
        keystrokeCadence: Double? = nil,
        suggestionShown: Int? = nil,
        suggestionTaken: Int? = nil
    ) {
        self.ts = ts
        self.deviceId = deviceId
        self.appId = appId
        self.kind = kind
        self.textIn = textIn
        self.textOut = textOut
        self.ocrDigest = ocrDigest
        self.asrDigest = asrDigest
        self.keystrokeCadence = keystrokeCadence
        self.suggestionShown = suggestionShown
        self.suggestionTaken = suggestionTaken
    }

    enum CodingKeys: String, CodingKey {
        case ts, deviceId = "device_id", appId = "app_id", kind
        case textIn = "text_in", textOut = "text_out"
        case ocrDigest = "ocr_digest", asrDigest = "asr_digest"
        case keystrokeCadence = "keystroke_cadence"
        case suggestionShown = "suggestion_shown", suggestionTaken = "suggestion_taken"
    }

    /// 摘要描述（日志打印用，字段级，不含全文拼接审计——FR6 精神）。
    public var fieldSummary: String {
        "kind=\(kind.rawValue) app=\(appId) in_len=\(textIn.count) out_len=\(textOut.count) " +
        "shown=\(suggestionShown.map(String.init) ?? "-") taken=\(suggestionTaken.map(String.init) ?? "-")"
    }
}
