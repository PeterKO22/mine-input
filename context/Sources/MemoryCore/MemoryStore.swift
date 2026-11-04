import ContextCore
import Foundation

/// 记忆层 store —— JSONL 对话记忆库（§15.1）：
/// `~/Library/Application Support/mine-input/memory/YYYY-MM-DD.jsonl`，一行一条，append-only 落盘。
///
/// 隐私联动（§15.1 / FR4，硬约束）：
/// 1. **熔断停记**：熔断标志（InteractionStore meta，跨进程）开启时 append 一律拒收，
///    记忆保留不新增；
/// 2. **一键清空**：`MemoryPrivacy.clearAll` 事件层+记忆层同清；
/// 3. **手工编辑**（N8/§15.3）：edit 重写当日文件；**删除=物理移除该行**（无 tombstone），
///    物理移除后导出/同步不再包含该条（撤回停传的落法）；
/// 4. C1 摘要（ocr/asr/screen digest）只落摘要+长度，绝不落原文/原图。
public final class MemoryStore {
    public enum MemoryError: Error, CustomStringConvertible, Equatable {
        case breakerTripped
        case notFound(String)
        case invalid(String)
        case ioFailed(String)

        public var description: String {
            switch self {
            case .breakerTripped:
                return "circuit breaker tripped: memory recording stopped"
            case .notFound(let id):
                return "memory not found: \(id)"
            case .invalid(let m):
                return "invalid: \(m)"
            case .ioFailed(let m):
                return "io failed: \(m)"
            }
        }
    }

    /// 落盘结果：熔断时拒收（记忆保留不新增）。
    public enum AppendResult: Equatable {
        case appended(id: String)
        case refused(MemoryError)

        public var id: String? {
            if case .appended(let id) = self { return id }
            return nil
        }
    }

    /// 记忆库根目录（默认 §15.1 路径；MINE_MEMORY_DIR 可覆盖，测试/demo 用）。
    public static func defaultRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["MINE_MEMORY_DIR"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        let base = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? "/tmp"
        return (base as NSString).appendingPathComponent("mine-input/memory")
    }

    public let rootDir: String
    private let lock = NSLock()
    private let breakerCheck: () -> Bool

    /// - Parameter breakerCheck: 熔断判定（默认读 InteractionStore meta）；nil=恒 false（纯离线场景）。
    public init(rootDir: String = MemoryStore.defaultRoot(), breakerCheck: (() -> Bool)? = nil) {
        self.rootDir = (rootDir as NSString).expandingTildeInPath
        self.breakerCheck = breakerCheck ?? { false }
        try? FileManager.default.createDirectory(
            atPath: self.rootDir, withIntermediateDirectories: true)
    }

    /// 与事件层联动的构造：熔断状态取 InteractionStore meta（跨进程）。
    public convenience init(rootDir: String = MemoryStore.defaultRoot(), interactionStore: InteractionStore) {
        self.init(rootDir: rootDir, breakerCheck: { interactionStore.isBreakerTripped })
    }

    // ------------------------------------------------------------ append

    /// 追加一条记忆（append-only 进当日文件）。熔断停记：拒收且不新增。
    @discardableResult
    public func append(_ record: MemoryRecord) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        if breakerCheck() { return .refused(.breakerTripped) }
        do {
            let line = try record.jsonLine()
            let path = dayFilePath(record.dayKey())
            let fm = FileManager.default
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil)
            }
            guard let h = FileHandle(forWritingAtPath: path) else {
                return .refused(.ioFailed("open \(path)"))
            }
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data((line + "\n").utf8))
            return .appended(id: record.id)
        } catch {
            return .refused(.ioFailed("\(error)"))
        }
    }

    // ------------------------------------------------------------ 查询

    /// 可查：关键词（情境/回复/线程，大小写不敏感）× 应用 × 起始时间；时间倒序。
    public func query(
        keyword: String? = nil,
        app: String? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) -> [MemoryRecord] {
        let sinceMs = since.map { Int64($0.timeIntervalSince1970 * 1000) }
        return allRecords()
            .filter { rec in
                if let sinceMs = sinceMs, rec.tsMs < sinceMs { return false }
                if let app = app, !app.isEmpty,
                    !rec.appId.lowercased().contains(app.lowercased()) {
                    return false
                }
                if let kw = keyword, !kw.isEmpty {
                    let hay = (rec.situation.beforeCursor + "\n" + rec.myReply.text + "\n"
                        + rec.situation.thread.joined(separator: "\n")).lowercased()
                    if !hay.contains(kw.lowercased()) { return false }
                }
                return true
            }
            .sorted { $0.tsMs > $1.tsMs }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// 最近 N 条（时间倒序，新→旧）。
    public func recent(_ n: Int = 5) -> [MemoryRecord] {
        query(limit: n)
    }

    /// suggest 上下文注入接口（§15.1「最近 N 条自动注入 suggest 上下文」）：
    /// 返回「情境→回复」紧凑行（按时间正序，旧→新，供拼进提示前缀）。
    public func recentForSuggest(_ n: Int = 5) -> [String] {
        recent(n).reversed().map { rec in
            "[\(rec.ts)] 情境:\(rec.situation.beforeCursor) → 我回:\(rec.myReply.text)"
        }
    }

    /// 全量（时间正序）。坏行跳过但保留在文件里（重写时原样保留，防数据丢失）。
    public func allRecords() -> [MemoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readAllUnlocked().map { $0.record }
    }

    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readAllUnlocked().count
    }

    /// 会话幂等判定（配对重放去重用）。
    public func hasSession(_ sessionId: String) -> Bool {
        allRecords().contains { $0.meta.sessionId == sessionId }
    }

    // ------------------------------------------------------------ 手工编辑 / 删除（N8/§15.3）

    /// 手工编辑：**重写当日文件**（§15.1 手工调整）。未给的字段保持原值。
    @discardableResult
    public func edit(
        id: String,
        beforeCursor: String? = nil,
        thread: [String]? = nil,
        replyText: String? = nil,
        mode: MyReply.Mode? = nil
    ) throws -> MemoryRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let day = locateDayUnlocked(id: id) else { throw MemoryError.notFound(id) }
        var updated: MemoryRecord?
        try rewriteUnlocked(whereDay: day) { rec in
            guard rec.id == id else { return rec }
            var r = rec
            if let beforeCursor = beforeCursor { r.situation.beforeCursor = beforeCursor }
            if let thread = thread { r.situation.thread = thread }
            if let replyText = replyText { r.myReply.text = replyText }
            if let mode = mode { r.myReply.mode = mode }
            updated = r
            return r
        }
        guard let out = updated else { throw MemoryError.notFound(id) }
        return out
    }

    /// 删除条目：**物理移除该行**（重写当日文件，无 tombstone）。
    /// 物理移除后该条不再出现在查询/导出/同步（撤回停传）。
    @discardableResult
    public func delete(id: String) throws -> MemoryRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let day = locateDayUnlocked(id: id) else { throw MemoryError.notFound(id) }
        var removed: MemoryRecord?
        try rewriteUnlocked(whereDay: day) { rec in
            if rec.id == id { removed = rec }
            return rec.id == id ? nil : rec
        }
        guard let out = removed else { throw MemoryError.notFound(id) }
        return out
    }

    /// 清空记忆层（一键清空的记侧）：删除全部当日文件，返回删除条数。
    public func clearAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = readAllUnlocked().count
        let fm = FileManager.default
        for f in dayFilesUnlocked() {
            try? fm.removeItem(atPath: f)
        }
        return n
    }

    // ------------------------------------------------------------ 同步挂钩（(d)）

    /// 导出为 W8 同构事件体 JSONL（一行一个 /v1/ingest 事件体，直进 ingest 队列）。
    public func exportIngestJSONL(deviceId: String, query q: (keyword: String?, app: String?, since: Date?, limit: Int)? = nil) -> String {
        let records: [MemoryRecord]
        if let q = q {
            records = query(keyword: q.keyword, app: q.app, since: q.since, limit: q.limit)
        } else {
            records = allRecords()
        }
        return MemorySync.exportIngestJSONL(records, deviceId: deviceId)
    }

    // ------------------------------------------------------------ internals

    private func dayFilePath(_ dayKey: String) -> String {
        (rootDir as NSString).appendingPathComponent("\(dayKey).jsonl")
    }

    private func dayFilesUnlocked() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: rootDir)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }
            .map { (rootDir as NSString).appendingPathComponent($0) }
            .sorted()
    }

    private struct RawEntry {
        var record: MemoryRecord
        var line: String
    }

    /// 读全部（文件名序=日期序；文件内行序保持追加序）。坏行解码失败 → 跳过（rewrite 时原样保留）。
    private func readAllUnlocked() -> [RawEntry] {
        var out: [RawEntry] = []
        for f in dayFilesUnlocked() {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                if let rec = MemoryRecord.decode(line: s) {
                    out.append(RawEntry(record: rec, line: s))
                }
            }
        }
        return out
    }

    /// 定位记录所在当日文件（YYYY-MM-DD）。
    private func locateDayUnlocked(id: String) -> String? {
        for f in dayFilesUnlocked() {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let rec = MemoryRecord.decode(line: String(line)), rec.id == id {
                    return ((f as NSString).lastPathComponent as NSString).deletingPathExtension
                }
            }
        }
        return nil
    }

    /// 重写当日文件（手工编辑/删除）：map 返回 nil=物理移除该行；坏行原样保留。
    private func rewriteUnlocked(
        whereDay: String?,
        _ transform: (MemoryRecord) -> MemoryRecord?
    ) throws {
        let files = dayFilesUnlocked().filter { f in
            guard let d = whereDay else { return true }
            return (f as NSString).lastPathComponent == "\(d).jsonl"
        }
        for f in files {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            var outLines: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                if let rec = MemoryRecord.decode(line: s) {
                    if let newRec = transform(rec) {
                        outLines.append((try? newRec.jsonLine()) ?? s)
                    }
                    // 返回 nil → 物理移除（不再追加该行）
                } else {
                    outLines.append(s) // 坏行原样保留
                }
            }
            let body = outLines.isEmpty ? "" : outLines.joined(separator: "\n") + "\n"
            do {
                try body.write(toFile: f, atomically: true, encoding: .utf8)
            } catch {
                throw MemoryError.ioFailed("\(error)")
            }
        }
    }
}

// ------------------------------------------------------------ 隐私联动（(c)）

/// 一键清空：**事件层 + 记忆层同清**（§15.1 隐私联动）。
public enum MemoryPrivacy {
    public static func clearAll(
        memory: MemoryStore, events: InteractionStore
    ) -> (memories: Int, events: Int) {
        let m = memory.clearAll()
        let e = events.clearAll()
        return (m, e)
    }
}
