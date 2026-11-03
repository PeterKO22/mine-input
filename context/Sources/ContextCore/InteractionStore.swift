import Foundation
import SQLite3

/// sqlite3_bind_text 的析构语义常量（sqliteTransient 宏 Swift 不可导入，标准替代）。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 交互日志 store —— 本地 SQLite（§8.2：时间索引事件流，默认 30 天滚动，可查可导可清）。
///
/// 表 `events` 列与 InteractionEvent（技术方案 §8.2 / hub IngestIn）逐字段对齐；
/// `meta` 表存全局状态（device_id / 熔断标志）——熔断跨进程生效，日志保留但不再新增。
public final class InteractionStore {
    public enum StoreError: Error, CustomStringConvertible, Equatable {
        case openFailed(String)
        case execFailed(String)
        case tripped // 熔断开启，采集立即停（FR4）
        case secureInputPaused // 安全输入（密码框/支付）自动暂停，不可关（FR4）
        public var description: String {
            switch self {
            case .openFailed(let m): return "open failed: \(m)"
            case .execFailed(let m): return "exec failed: \(m)"
            case .tripped: return "circuit breaker tripped: collection stopped"
            case .secureInputPaused: return "secure input: auto-paused (cannot be disabled)"
            }
        }
    }

    /// 插入结果：熔断/安全输入时拒绝且日志不新增。
    public enum InsertResult: Equatable {
        case stored(id: Int64)
        case refused(StoreError)

        public var storedId: Int64? {
            if case .stored(let id) = self { return id }
            return nil
        }
        public var isRefused: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "mine.input.interaction-store")
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != path {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        if sqlite3_open_v2(
            path, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK,
            let h = handle {
            let msg = String(cString: sqlite3_errmsg(h))
            sqlite3_close(h)
            throw StoreError.openFailed(msg)
        }
        guard let h = handle else { throw StoreError.openFailed("nil handle") }
        db = h
        try exec("""
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                device_id TEXT NOT NULL,
                app_id TEXT NOT NULL DEFAULT '',
                kind TEXT NOT NULL CHECK(kind IN
                    ('key_session','voice_session','candidate_pick','suggestion_feedback')),
                text_in TEXT NOT NULL DEFAULT '',
                text_out TEXT NOT NULL DEFAULT '',
                ocr_digest TEXT,
                asr_digest TEXT,
                keystroke_cadence REAL,
                suggestion_shown INTEGER,
                suggestion_taken INTEGER
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
    }

    deinit { sqlite3_close(db) }

    // ------------------------------------------------------------ meta

    public func metaGet(_ key: String) -> String? {
        queue.sync {
            let stmt = prepare("SELECT value FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    public func metaSet(_ key: String, _ value: String) {
        queue.sync {
            let stmt = prepare(
                "INSERT INTO meta(key,value) VALUES(?,?) " +
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, value, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
    }

    /// 熔断全局标志（跨进程持久）：true = 一切采集立即停，日志保留不新增。
    public var isBreakerTripped: Bool { metaGet("breaker") == "1" }

    /// 稳定设备 ID（首次生成后持久化）。
    public func deviceId(override: String? = nil) -> String {
        if let o = override, !o.isEmpty { return o }
        if let env = ProcessInfo.processInfo.environment["MINE_DEVICE_ID"], !env.isEmpty {
            return env
        }
        if let saved = metaGet("device_id"), !saved.isEmpty { return saved }
        let host = (ProcessInfo.processInfo.hostName).split(separator: ".").first
            .map(String.init) ?? "mac"
        let generated = "mac-\(host)"
        metaSet("device_id", generated)
        return generated
    }

    // ------------------------------------------------------------ insert

    /// 交互事件入库 API（供 W7 输入会话上报）。熔断开启或安全输入时拒绝且不新增日志。
    public func insert(
        _ ev: InteractionEvent,
        secureInput: Bool = false
    ) -> InsertResult {
        if isBreakerTripped { return .refused(.tripped) }
        if secureInput { return .refused(.secureInputPaused) }
        return queue.sync {
            let stmt = prepare("""
                INSERT INTO events(ts, device_id, app_id, kind, text_in, text_out,
                                   ocr_digest, asr_digest, keystroke_cadence,
                                   suggestion_shown, suggestion_taken)
                VALUES(?,?,?,?,?,?,?,?,?,?,?);
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, ev.ts)
            bind(stmt, 2, ev.deviceId)
            bind(stmt, 3, ev.appId)
            bind(stmt, 4, ev.kind.rawValue)
            bind(stmt, 5, ev.textIn)
            bind(stmt, 6, ev.textOut)
            bind(stmt, 7, ev.ocrDigest)
            bind(stmt, 8, ev.asrDigest)
            if let c = ev.keystrokeCadence {
                sqlite3_bind_double(stmt, 9, c)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let n = ev.suggestionShown {
                sqlite3_bind_int64(stmt, 10, Int64(n))
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let n = ev.suggestionTaken {
                sqlite3_bind_int64(stmt, 11, Int64(n))
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                return .refused(.execFailed(lastError()))
            }
            return .stored(id: sqlite3_last_insert_rowid(db))
        }
    }

    // ------------------------------------------------------------ query

    public struct Query {
        public var limit: Int = 50
        public var kind: EventKind? = nil
        public var sinceMs: Int64? = nil
        public var untilMs: Int64? = nil
        public init(
            limit: Int = 50, kind: EventKind? = nil,
            sinceMs: Int64? = nil, untilMs: Int64? = nil
        ) {
            self.limit = limit
            self.kind = kind
            self.sinceMs = sinceMs
            self.untilMs = untilMs
        }
    }

    public func count(kind: EventKind? = nil) -> Int {
        queue.sync {
            let sql = kind == nil
                ? "SELECT COUNT(*) FROM events;"
                : "SELECT COUNT(*) FROM events WHERE kind = ?;"
            let stmt = prepare(sql)
            defer { sqlite3_finalize(stmt) }
            if let k = kind { sqlite3_bind_text(stmt, 1, k.rawValue, -1, sqliteTransient) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// 可查：时间倒序，可按 kind / 时间窗过滤。
    public func query(_ q: Query = Query()) -> [InteractionEvent] {
        queue.sync {
            var sql = "SELECT ts, device_id, app_id, kind, text_in, text_out, " +
                "ocr_digest, asr_digest, keystroke_cadence, suggestion_shown, suggestion_taken " +
                "FROM events WHERE 1=1"
            if q.kind != nil { sql += " AND kind = ?" }
            if q.sinceMs != nil { sql += " AND ts >= ?" }
            if q.untilMs != nil { sql += " AND ts <= ?" }
            sql += " ORDER BY ts DESC, id DESC LIMIT ?;"
            let stmt = prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            if let k = q.kind {
                sqlite3_bind_text(stmt, idx, k.rawValue, -1, sqliteTransient)
                idx += 1
            }
            if let s = q.sinceMs { sqlite3_bind_int64(stmt, idx, s); idx += 1 }
            if let u = q.untilMs { sqlite3_bind_int64(stmt, idx, u); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(q.limit))
            var out: [InteractionEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(rowToEvent(stmt))
            }
            return out
        }
    }

    // ------------------------------------------------------------ export / clear

    /// 可导：JSONL（snake_case，与 hub IngestIn 同名字段）或 CSV。
    public func exportJSONL(_ q: Query = Query(limit: 1_000_000)) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return query(q).compactMap { ev -> String? in
            // InteractionEvent 的 CodingKeys 即 snake_case（device_id/text_in/…），
            // 直接编码即与 hub /v1/ingest 事件体同构（ts 为整数、nil 字段省略）。
            guard let data = try? enc.encode(ev) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n") + "\n"
    }

    public func exportCSV(_ q: Query = Query(limit: 1_000_000)) -> String {
        let header = "ts,device_id,app_id,kind,text_in,text_out,ocr_digest,asr_digest," +
            "keystroke_cadence,suggestion_shown,suggestion_taken"
        var lines: [String] = [header]
        for ev in query(q) {
            let row: [String] = [
                String(ev.ts),
                csvEscape(ev.deviceId),
                csvEscape(ev.appId),
                ev.kind.rawValue,
                csvEscape(ev.textIn),
                csvEscape(ev.textOut),
                csvEscape(ev.ocrDigest ?? ""),
                csvEscape(ev.asrDigest ?? ""),
                ev.keystrokeCadence.map { String($0) } ?? "",
                ev.suggestionShown.map { String($0) } ?? "",
                ev.suggestionTaken.map { String($0) } ?? "",
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV 字段转义（逗号/引号/换行包裹引号）。
    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// 可一键清空：删除全部事件（meta 保留——熔断/设备 ID 不受影响）。
    public func clearAll() -> Int {
        queue.sync {
            let n = countUnlocked()
            execUnlocked("DELETE FROM events;")
            return n
        }
    }

    /// 30 天滚动（§8.2）：删掉 ts 早于截止线的事件，返回删除条数。
    public func prune(olderThanDays days: Int = 30, now: Date = Date()) -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000)
            - Int64(days) * 24 * 3600 * 1000
        return queue.sync {
            let stmt = prepare("DELETE FROM events WHERE ts < ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// 导出建表语句（验收可读）。
    public func schemaSQL() -> String {
        queue.sync {
            let stmt = prepare(
                "SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name;")
            defer { sqlite3_finalize(stmt) }
            var lines: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                lines.append(String(cString: sqlite3_column_text(stmt, 0)) + ";")
            }
            return lines.joined(separator: "\n")
        }
    }

    // ------------------------------------------------------------ internals

    private func countUnlocked() -> Int {
        let stmt = prepare("SELECT COUNT(*) FROM events;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func rowToEvent(_ stmt: OpaquePointer?) -> InteractionEvent {
        func str(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: p)
        }
        func optStr(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func optInt(_ i: Int32) -> Int? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, i))
        }
        func optDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, i)
        }
        return InteractionEvent(
            ts: sqlite3_column_int64(stmt, 0),
            deviceId: str(1),
            appId: str(2),
            kind: EventKind(rawValue: str(3)) ?? .keySession,
            textIn: str(4),
            textOut: str(5),
            ocrDigest: optStr(6),
            asrDigest: optStr(7),
            keystrokeCadence: optDouble(8),
            suggestionShown: optInt(9),
            suggestionTaken: optInt(10)
        )
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ v: String?) {
        if let v = v {
            sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func execUnlocked(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let e = err { sqlite3_free(e) }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            if let e = err { sqlite3_free(e) }
            throw StoreError.execFailed(msg)
        }
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
