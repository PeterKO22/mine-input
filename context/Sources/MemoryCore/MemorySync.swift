import ContextCore
import Foundation

/// 同步挂钩（§15.1「记忆层可选同步进 Hub（ingest 队列）」）：
/// 记忆 → **W8 同构事件体**（sdk `ser::event_to_json` / hub `/v1/ingest` `IngestIn`
/// 的 InteractionEvent 字段：ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/
/// asr_digest?/keystroke_cadence?/suggestion_shown?/suggestion_taken?）。
/// 导出为 JSONL：**一行一个事件体，直进 ingest 队列**（sdk OfflineQueue `enqueue_ingest`
/// 或 POST /v1/ingest 逐行投递）。
///
/// 映射（记忆 → 事件体）：
/// | 记忆字段 | 事件体字段 |
/// |---|---|
/// | ts（ISO8601） | ts（Unix 毫秒） |
/// | device | device_id |
/// | app_id | app_id |
/// | my_reply.mode=text|voice | kind=key_session|voice_session |
/// | situation.before_cursor | text_in |
/// | my_reply.text | text_out |
/// | situation.ocr_digest / asr_digest | ocr_digest / asr_digest |
/// | meta.from_suggestion 非空 | suggestion_taken=1 |
///
/// 隐私联动：导出/同步**只含当前仍在库的记录**——删除即物理移除，
/// 被删条目不会出现在任何后续导出/同步（撤回停传的落法）。
public enum MemorySync {
    /// 记忆 → W8 同构事件体（InteractionEvent，snake_case JSON 即 /v1/ingest 请求体）。
    public static func ingestEvent(from m: MemoryRecord, deviceId: String) -> InteractionEvent {
        InteractionEvent(
            ts: m.tsMs,
            deviceId: deviceId,
            appId: m.appId,
            kind: m.myReply.mode == .voice ? .voiceSession : .keySession,
            textIn: m.situation.beforeCursor,
            textOut: m.myReply.text,
            ocrDigest: m.situation.ocrDigest,
            asrDigest: m.situation.asrDigest,
            keystrokeCadence: nil,
            suggestionShown: nil,
            suggestionTaken: m.meta.fromSuggestion.isEmpty ? nil : 1)
    }

    /// 一行事件体 JSONL（可直进 ingest 队列）。
    public static func ingestJSONLLine(from m: MemoryRecord, deviceId: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ev = ingestEvent(from: m, deviceId: deviceId)
        guard let data = try? enc.encode(ev) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 批量导出：一行一个 W8 同构事件体。
    public static func exportIngestJSONL(_ records: [MemoryRecord], deviceId: String) -> String {
        records
            .map { ingestJSONLLine(from: $0, deviceId: deviceId) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n") + (records.isEmpty ? "" : "\n")
    }
}

/// ingest 队列投递口（同步挂钩的接口面）：W8 sdk 的 OfflineQueue / 未来的同步
/// worker 实现本协议即可接走记忆层导出；MVP 附 JSONL 文件队列实现
/// （JSONL 直进 ingest 队列：落一个事件体一行的队列文件，worker 逐行取用）。
public protocol IngestQueueSink {
    func enqueue(line: String) throws
}

/// JSONL 文件队列 sink：append-only，一行一个 /v1/ingest 事件体。
public final class JSONLQueueSink: IngestQueueSink {
    public let path: String

    public init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != path {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
        }
    }

    public func enqueue(line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw MemoryStore.MemoryError.ioFailed("open \(path)")
        }
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    /// 投递一批记忆：返回入队条数。
    @discardableResult
    public func enqueueAll(_ records: [MemoryRecord], deviceId: String) throws -> Int {
        var n = 0
        for m in records {
            let line = MemorySync.ingestJSONLLine(from: m, deviceId: deviceId)
            guard !line.isEmpty else { continue }
            try enqueue(line: line)
            n += 1
        }
        return n
    }
}
