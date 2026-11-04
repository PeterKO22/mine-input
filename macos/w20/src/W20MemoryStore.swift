// W20MemoryStore.swift — 记忆管理数据层（N8，docs/技术方案-v0.4.md §15.1/§15.3）
//
// 读写 W19 交付的记忆 JSONL（schema 已在 §15.1 定死，UI 不等 W19、按 schema 开发）：
//   ~/Library/Application Support/mine-input/memory/YYYY-MM-DD.jsonl，一行一条：
//   {"id","ts","device","app_id","situation"{before_cursor,screen_digest,ocr_digest,
//    asr_digest,thread[]},"my_reply"{text,mode},"meta"{from_suggestion,confidence,
//    session_id},"consent"}
//
// 操作语义（§15.1 隐私联动 + §15.3 界面能力）：
//   - 查看：按日分组时间线（文件名即日分组键）；
//   - 搜索：keyword 命中 my_reply.text / situation.before_cursor / situation.thread，
//     可按 app / since(YYYY-MM-DD) 过滤（对齐 memoryctl query 语义）；
//   - 编辑：改 situation（before_cursor / thread）与 my_reply（text / mode），
//     **重写当日文件**（未改动的行原样保留，杜绝丢字段）；
//   - 删除：物理移除该行（§15.1「删除即物理移除该行」）；
//   - 导出：所选条目写回 JSONL（可查可导）。
//
// 采集状态 + 一键熔断（§15.3 顶部常显）：熔断走 ContextCore CircuitBreaker
// （store meta `breaker`，跨进程持久，W19「熔断停记」同源），协议抽象便于测试。
import Foundation

// MARK: - 记忆条目（§15.1 schema）

public struct W20Situation: Codable, Equatable {
    public var beforeCursor: String?
    public var screenDigest: String?
    public var ocrDigest: String?
    public var asrDigest: String?
    public var thread: [String]?

    public init(beforeCursor: String? = nil, screenDigest: String? = nil,
                ocrDigest: String? = nil, asrDigest: String? = nil,
                thread: [String]? = nil) {
        self.beforeCursor = beforeCursor
        self.screenDigest = screenDigest
        self.ocrDigest = ocrDigest
        self.asrDigest = asrDigest
        self.thread = thread
    }

    enum CodingKeys: String, CodingKey {
        case beforeCursor = "before_cursor"
        case screenDigest = "screen_digest"
        case ocrDigest = "ocr_digest"
        case asrDigest = "asr_digest"
        case thread
    }
}

public struct W20MyReply: Codable, Equatable {
    public var text: String?
    public var mode: String?  // "text" | "voice"

    public init(text: String? = nil, mode: String? = nil) {
        self.text = text
        self.mode = mode
    }
}

public struct W20Meta: Codable, Equatable {
    public var fromSuggestion: String?  // "prop_id|"
    public var confidence: Double?
    public var sessionId: String?

    public init(fromSuggestion: String? = nil, confidence: Double? = nil,
                sessionId: String? = nil) {
        self.fromSuggestion = fromSuggestion
        self.confidence = confidence
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case fromSuggestion = "from_suggestion"
        case confidence
        case sessionId = "session_id"
    }
}

public struct W20MemoryEntry: Codable, Equatable {
    public var id: String
    public var ts: String
    public var device: String?
    public var appId: String?
    public var situation: W20Situation?
    public var myReply: W20MyReply?
    public var meta: W20Meta?
    public var consent: String?

    public init(id: String, ts: String, device: String? = nil, appId: String? = nil,
                situation: W20Situation? = nil, myReply: W20MyReply? = nil,
                meta: W20Meta? = nil, consent: String? = nil) {
        self.id = id
        self.ts = ts
        self.device = device
        self.appId = appId
        self.situation = situation
        self.myReply = myReply
        self.meta = meta
        self.consent = consent
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, device
        case appId = "app_id"
        case situation
        case myReply = "my_reply"
        case meta, consent
    }

    /// 搜索命中面（keyword 匹配的文本字段）。
    public var searchableText: String {
        var parts: [String] = []
        if let t = myReply?.text { parts.append(t) }
        if let b = situation?.beforeCursor { parts.append(b) }
        if let th = situation?.thread { parts.append(th.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 采集状态 / 一键熔断（§15.3 顶部常显）

/// 熔断控制抽象（UI 顶部「一键熔断开关」的数据源）。
/// 生产实现 = ContextCore CircuitBreaker（store meta，跨进程持久）；测试用桩。
public protocol W20BreakerControl: AnyObject {
    var isTripped: Bool { get }
    func trip()    // 一键熔断：立即停采集（W19 熔断停记同源）
    func reset()   // 解除熔断（显式操作才恢复）
}

public struct W20CollectionStatus: Equatable {
    public var breakerTripped: Bool
    public var todayCount: Int
    public var totalCount: Int

    public init(breakerTripped: Bool, todayCount: Int, totalCount: Int) {
        self.breakerTripped = breakerTripped
        self.todayCount = todayCount
        self.totalCount = totalCount
    }

    /// 采集中 / 已熔断（界面文案）。
    public var label: String { breakerTripped ? "已熔断（停采集）" : "采集中" }
}

// MARK: - 记忆存储（JSONL 按日文件）

public final class W20MemoryStore {
    /// 默认目录 = §15.1 约定；测试/脚本可注入。
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/mine-input/memory",
                                    isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? W20MemoryStore.defaultDirectory()
    }

    // MARK: 读取

    /// 日分组键（YYYY-MM-DD），降序（新日在前）。
    public func days() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
            .filter { $0.count == 10 }
            .sorted(by: >)
    }

    /// 某日条目（文件内顺序 = 落盘顺序）。
    public func entries(day: String) -> [W20MemoryEntry] {
        rawLines(day: day).compactMap { parseLine($0.raw) }
    }

    /// 全部条目（新日在前）。
    public func allEntries() -> [W20MemoryEntry] {
        days().flatMap { entries(day: $0) }
    }

    /// 按 id 查（跨日）。
    public func find(id: String) -> (day: String, entry: W20MemoryEntry)? {
        for day in days() {
            for e in entries(day: day) where e.id == id {
                return (day, e)
            }
        }
        return nil
    }

    /// 检索（§15.1 memoryctl query 语义：keyword / app / since）。
    /// keyword 命中 my_reply.text / situation.before_cursor / situation.thread（大小写不敏感）。
    public func search(keyword: String? = nil, app: String? = nil,
                       since: String? = nil) -> [W20MemoryEntry] {
        let kw = (keyword ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return allEntries().filter { e in
            if let app, e.appId != app { return false }
            if let since, String(e.ts.prefix(10)) < since { return false }
            if !kw.isEmpty, !e.searchableText.lowercased().contains(kw) { return false }
            return true
        }
    }

    /// 采集状态（顶部常显）：熔断态 + 今日/累计条数。
    public func collectionStatus(breaker: W20BreakerControl?) -> W20CollectionStatus {
        let today = String(dayStamp().prefix(10))
        let days = self.days()
        return W20CollectionStatus(
            breakerTripped: breaker?.isTripped ?? false,
            todayCount: days.contains(today) ? entries(day: today).count : 0,
            totalCount: days.reduce(0) { $0 + entries(day: $1).count })
    }

    // MARK: 编辑（重写当日文件；未改动行原样保留）

    /// 改 situation（before_cursor / thread）与 my_reply（text / mode）。
    /// 非 nil 参数才替换对应字段；成功返回 true。语义：§15.1 手工编辑重写当日文件。
    @discardableResult
    public func update(id: String,
                       beforeCursor: String? = nil,
                       thread: [String]? = nil,
                       replyText: String? = nil,
                       replyMode: String? = nil) -> Bool {
        guard let day = find(id: id)?.day else { return false }
        var changed = false
        rewrite(day: day) { obj in
            guard (obj["id"] as? String) == id else { return false }
            if beforeCursor != nil || thread != nil {
                var sit = obj["situation"] as? [String: Any] ?? [:]
                if let beforeCursor { sit["before_cursor"] = beforeCursor }
                if let thread { sit["thread"] = thread }
                obj["situation"] = sit
            }
            if replyText != nil || replyMode != nil {
                var rep = obj["my_reply"] as? [String: Any] ?? [:]
                if let replyText { rep["text"] = replyText }
                if let replyMode { rep["mode"] = replyMode }
                obj["my_reply"] = rep
            }
            changed = true
            return true
        }
        return changed
    }

    /// 删除：物理移除该行（§15.1）。文件空则移除当日文件。
    @discardableResult
    public func delete(id: String) -> Bool {
        guard let day = find(id: id)?.day else { return false }
        let kept = rawLines(day: day).filter { parseLine($0.raw)?.id != id }
        write(day: day, raws: kept.map(\.raw))
        return true
    }

    // MARK: 导出

    /// 导出 JSONL（可查可导）。
    public func export(entries: [W20MemoryEntry], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var out = ""
        for e in entries {
            let data = try enc.encode(AnyEncodable(e.asDictionary()))
            out += String(data: data, encoding: .utf8) ?? ""
            out += "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 底层（JSONL 行）

    struct RawLine {
        let raw: String
    }

    private func filePath(day: String) -> URL {
        directory.appendingPathComponent("\(day).jsonl")
    }

    private func rawLines(day: String) -> [RawLine] {
        guard let text = try? String(contentsOf: filePath(day: day), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { RawLine(raw: String($0)) }
    }

    private func parseLine(_ raw: String) -> W20MemoryEntry? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(W20MemoryEntry.self, from: data)
    }

    /// 重写当日文件：mutate 返回 true 才重编码该行（其余行原样保留，杜绝丢字段）。
    private func rewrite(day: String, mutate: (inout [String: Any]) -> Bool) {
        let lines = rawLines(day: day)
        var out: [String] = []
        for line in lines {
            guard let data = line.raw.data(using: .utf8),
                  var obj = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else {
                out.append(line.raw)  // 解析不动的行原样保留
                continue
            }
            if mutate(&obj),
               let data = try? JSONSerialization.data(
                   withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                out.append(s)
            } else {
                out.append(line.raw)  // 未改动的行字节级原样
            }
        }
        write(day: day, raws: out)
    }

    private func write(day: String, raws: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = filePath(day: day)
        if raws.isEmpty {
            try? fm.removeItem(at: url)  // 空文件移除（该日已无记忆）
            return
        }
        let text = raws.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func dayStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}

// MARK: - 工具

private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ dict: [String: Any]) {
        encodeFunc = { enc in
            var c = enc.singleValueContainer()
            try c.encode(dict.mapValues(AnyValue.init))
        }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

private struct AnyValue: Encodable {
    private let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyValue.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyValue.init))
        case is NSNull: try c.encodeNil()
        default: try c.encode("\(value)")
        }
    }
}

extension W20MemoryEntry {
    /// 供导出/重编码用的字典形态（键 = §15.1 schema）。
    public func asDictionary() -> [String: Any] {
        var d: [String: Any] = ["id": id, "ts": ts]
        if let device { d["device"] = device }
        if let appId { d["app_id"] = appId }
        if let situation {
            var s: [String: Any] = [:]
            if let v = situation.beforeCursor { s["before_cursor"] = v }
            if let v = situation.screenDigest { s["screen_digest"] = v }
            if let v = situation.ocrDigest { s["ocr_digest"] = v }
            if let v = situation.asrDigest { s["asr_digest"] = v }
            if let v = situation.thread { s["thread"] = v }
            d["situation"] = s
        }
        if let myReply {
            var r: [String: Any] = [:]
            if let v = myReply.text { r["text"] = v }
            if let v = myReply.mode { r["mode"] = v }
            d["my_reply"] = r
        }
        if let meta {
            var m: [String: Any] = [:]
            if let v = meta.fromSuggestion { m["from_suggestion"] = v }
            if let v = meta.confidence { m["confidence"] = v }
            if let v = meta.sessionId { m["session_id"] = v }
            d["meta"] = m
        }
        if let consent { d["consent"] = consent }
        return d
    }
}
