import Foundation

// W19 memory-jsonl —— 记忆层记录 schema（唯一规格源：docs/技术方案-v0.4.md §15.1）：
//
//   {"id":"uuid","ts":"ISO8601","device":"mac","app_id":"…",
//    "situation":{"before_cursor":"…","screen_digest":"sha256:… len:N","ocr_digest":"…","asr_digest":"…",
//                 "thread":["对方:…","我:…"]},
//    "my_reply":{"text":"…","mode":"text|voice"},
//    "meta":{"from_suggestion":"prop_id|","confidence":0.0,"session_id":"…"},
//    "consent":"c0|c1"}
//
// 一行一条，append-only 落盘：~/Library/Application Support/mine-input/memory/YYYY-MM-DD.jsonl。
// JSON 键名与 §15.1 逐字一致（snake_case），单测断言防漂移。

/// 记忆层记录 —— 「在什么情况下，我回了什么话」为单位（N6）。
public struct MemoryRecord: Codable, Equatable {
    /// uuid（§15.1）
    public var id: String
    /// ISO8601 时间（§15.1）
    public var ts: String
    /// 设备标识（§15.1：device，如 "mac"）
    public var device: String
    /// 应用（§15.1：app_id）
    public var appId: String
    /// 情境（§15.1：situation）
    public var situation: Situation
    /// 我的回复（§15.1：my_reply）
    public var myReply: MyReply
    /// 元信息（§15.1：meta）
    public var meta: Meta
    /// 同意分级（§15.1：consent，c0|c1）
    public var consent: Consent

    enum CodingKeys: String, CodingKey {
        case id, ts, device
        case appId = "app_id"
        case situation
        case myReply = "my_reply"
        case meta, consent
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        ts: String,
        device: String = "mac",
        appId: String = "",
        situation: Situation,
        myReply: MyReply,
        meta: Meta,
        consent: Consent = .c0
    ) {
        self.id = id
        self.ts = ts
        self.device = device
        self.appId = appId
        self.situation = situation
        self.myReply = myReply
        self.meta = meta
        self.consent = consent
    }

    /// 便捷构造：Unix 毫秒 → ISO8601（带毫秒，UTC）。
    public init(
        id: String = UUID().uuidString.lowercased(),
        tsMs: Int64,
        device: String = "mac",
        appId: String = "",
        situation: Situation,
        myReply: MyReply,
        meta: Meta,
        consent: Consent = .c0
    ) {
        self.init(
            id: id,
            ts: MemoryRecord.isoString(fromMs: tsMs),
            device: device,
            appId: appId,
            situation: situation,
            myReply: myReply,
            meta: meta,
            consent: consent)
    }

    // ------------------------------------------------------------ 时间工具

    /// ISO8601（带毫秒）→ Unix 毫秒；解析失败回退去掉毫秒再试，最终 0。
    public var tsMs: Int64 {
        let f = MemoryRecord.isoFractional
        if let d = f.date(from: ts) {
            return Int64((d.timeIntervalSince1970 * 1000).rounded())
        }
        if let d = MemoryRecord.isoPlain.date(from: ts) {
            return Int64((d.timeIntervalSince1970 * 1000).rounded())
        }
        return 0
    }

    public static func isoString(fromMs ms: Int64) -> String {
        isoFractional.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// ISO8601 字符串 → Date（毫秒优先，其次秒级）。
    public static func date(fromISO s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// 当日分区键（本地时区 YYYY-MM-DD，与存储文件名一致）。
    public func dayKey(timeZone: TimeZone = .current) -> String {
        MemoryRecord.dayKey(fromMs: tsMs, timeZone: timeZone)
    }

    public static func dayKey(fromMs ms: Int64, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // ------------------------------------------------------------ JSONL 编解码

    /// JSONL 行编码（键序稳定、不转义斜杠）。
    public func jsonLine() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: try enc.encode(self), encoding: .utf8) ?? ""
    }

    public static func decode(line: String) -> MemoryRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemoryRecord.self, from: data)
    }

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// ------------------------------------------------------------ situation

/// 情境（§15.1 situation）——「在什么情况下」。
public struct Situation: Codable, Equatable {
    /// 输入框上下文（当前光标前文本）
    public var beforeCursor: String
    /// 屏幕摘要（C1，sha256:… len:N；默认 nil 不采集）
    public var screenDigest: String?
    /// OCR 摘要（C1，仅摘要/长度，绝不落原文；默认 nil）
    public var ocrDigest: String?
    /// ASR 摘要（C1，仅摘要/长度；默认 nil）
    public var asrDigest: String?
    /// 会话线索（["对方:…","我:…"]）
    public var thread: [String]

    enum CodingKeys: String, CodingKey {
        case beforeCursor = "before_cursor"
        case screenDigest = "screen_digest"
        case ocrDigest = "ocr_digest"
        case asrDigest = "asr_digest"
        case thread
    }

    public init(
        beforeCursor: String = "",
        screenDigest: String? = nil,
        ocrDigest: String? = nil,
        asrDigest: String? = nil,
        thread: [String] = []
    ) {
        self.beforeCursor = beforeCursor
        self.screenDigest = screenDigest
        self.ocrDigest = ocrDigest
        self.asrDigest = asrDigest
        self.thread = thread
    }
}

// ------------------------------------------------------------ my_reply

/// 我的回复（§15.1 my_reply）——「我回了什么话」。
public struct MyReply: Codable, Equatable {
    /// 回复文本（上屏内容）
    public var text: String
    /// 回复方式（§15.1：text|voice）
    public var mode: Mode

    public enum Mode: String, Codable {
        case text
        case voice
    }

    public init(text: String, mode: Mode = .text) {
        self.text = text
        self.mode = mode
    }
}

// ------------------------------------------------------------ meta

/// 元信息（§15.1 meta）。
public struct Meta: Codable, Equatable {
    /// 建议来源提案 id（§15.1："prop_id|"；空串=非建议来源）
    public var fromSuggestion: String
    /// 置信度（§15.1：0.0 起）
    public var confidence: Double
    /// 输入会话 id（§15.1：session_id）
    public var sessionId: String

    enum CodingKeys: String, CodingKey {
        case fromSuggestion = "from_suggestion"
        case confidence
        case sessionId = "session_id"
    }

    public init(fromSuggestion: String = "", confidence: Double = 0.0, sessionId: String = "") {
        self.fromSuggestion = fromSuggestion
        self.confidence = confidence
        self.sessionId = sessionId
    }
}

// ------------------------------------------------------------ consent

/// 同意分级（§15.1 consent：c0|c1）。
public enum Consent: String, Codable {
    case c0
    case c1
}
