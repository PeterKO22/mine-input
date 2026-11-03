import Foundation

// suggest 客户端 —— 调 Hub /v1/suggest SSE（hub/W4-REPORT §1）或 Null 后端离线。
//
// 流式语义对齐 ai/spi/ai_assist.h（suggest 流式语义）：
//   先若干 kDelta 增量，后**恰好一次**终止事件（kDone/kError；超时由本客户端补 kTimeout）；
//   终止之后的更新一律丢弃。超时 800ms 弃本轮（NFR3）。

/// 建议项 —— 契约字段 text/score/source（ai_assist.h Candidate / hub SSE 同构）。
public struct Candidate: Codable, Equatable {
    public let text: String
    public let score: Double
    public let source: String
    public let seq: Int?

    public init(text: String, score: Double, source: String, seq: Int? = nil) {
        self.text = text
        self.score = score
        self.source = source
        self.seq = seq
    }
}

/// 流式状态（ai_assist.h StreamStatus 同名同义）。
public enum StreamStatus: String {
    case kDelta, kDone, kError, kTimeout
}

/// 流式更新（ai_assist.h SuggestUpdate）。
public struct SuggestUpdate {
    public let status: StreamStatus
    public let candidates: [Candidate]
    public let error: String

    public init(status: StreamStatus, candidates: [Candidate] = [], error: String = "") {
        self.status = status
        self.candidates = candidates
        self.error = error
    }
}

/// 调用上下文（hub SuggestIn 同构：before_cursor/app_id/from_voice/context_digest）。
public struct SuggestContext {
    public var beforeCursor: String
    public var appId: String
    public var fromVoice: Bool
    public var contextDigest: String

    public init(
        beforeCursor: String, appId: String = "",
        fromVoice: Bool = false, contextDigest: String = ""
    ) {
        self.beforeCursor = beforeCursor
        self.appId = appId
        self.fromVoice = fromVoice
        self.contextDigest = contextDigest
    }
}

/// suggest 后端协议（契约即协议：换 Hub/Null 零改动）。
public protocol SuggestBackend {
    /// 返回后经 on_update 增量推送；恰好一次终止事件（kDone/kError/kTimeout）。
    func suggest(
        ctx: SuggestContext,
        timeout: TimeInterval,
        onUpdate: @escaping (SuggestUpdate) -> Void
    ) async
}

// ------------------------------------------------------------ Null 后端（离线）

/// Null 后端 —— 离线兜底（对齐 ai/spi Null 后端思路）：
/// 本地生成确定性建议流，若干 kDelta 后恰好一次 kDone；不依赖网络。
public struct NullSuggestBackend: SuggestBackend {
    public init() {}

    public func suggest(
        ctx: SuggestContext,
        timeout: TimeInterval,
        onUpdate: @escaping (SuggestUpdate) -> Void
    ) async {
        let tail = String(ctx.beforeCursor.suffix(8))
        let items = [
            Candidate(text: "\(tail)——本地兜底建议一", score: 0.62, source: "null", seq: 1),
            Candidate(text: "\(tail)——本地兜底建议二", score: 0.51, source: "null", seq: 2),
            Candidate(text: "\(tail)——本地兜底建议三", score: 0.44, source: "null", seq: 3),
        ]
        for item in items {
            try? await Task.sleep(nanoseconds: 60_000_000) // 模拟增量到达节奏
            onUpdate(SuggestUpdate(status: .kDelta, candidates: [item]))
        }
        onUpdate(SuggestUpdate(status: .kDone))
    }
}

// ------------------------------------------------------------ Hub 后端（/v1/suggest SSE）

/// Hub /v1/suggest SSE 客户端（W4-REPORT §1：`event: suggestion` 每帧一个 Candidate，
/// 末帧 `event: done`）。Bearer 鉴权（/v1/auth/token）。
public struct HubSuggestBackend: SuggestBackend {
    public let baseURL: URL
    public let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func suggest(
        ctx: SuggestContext,
        timeout: TimeInterval,
        onUpdate: @escaping (SuggestUpdate) -> Void
    ) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/suggest"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "before_cursor": ctx.beforeCursor,
            "app_id": ctx.appId,
            "from_voice": ctx.fromVoice,
            "context_digest": ctx.contextDigest,
        ])

        let finished = FinishedFlag()
        // NFR3：800ms 超时弃本轮（可用 timeout 覆盖），超时补 kTimeout 终止。
        let streamTask = Task {
            do {
                let (bytes, response) = try await session.bytes(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = try await Self.readBody(bytes)
                    await finished.terminate(
                        SuggestUpdate(status: .kError, error: "http \(http.statusCode): \(body)"),
                        onUpdate: onUpdate)
                    return
                }
                var eventName = ""
                var dataLines: [String] = []
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") {
                        // 帧边界 = 下一个 event: 行（bytes.lines 可能吞掉空行，
                        // 不依赖空行分帧）：先冲刷上一帧，再开新帧。
                        if !eventName.isEmpty {
                            let ev = eventName
                            let data = dataLines.joined(separator: "\n")
                            eventName = ""
                            dataLines = []
                            await Self.dispatch(
                                event: ev, data: data,
                                finished: finished, onUpdate: onUpdate)
                        }
                        eventName = String(line.dropFirst(6))
                            .trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(
                            String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    }
                }
                await Self.dispatch(
                    event: eventName, data: dataLines.joined(separator: "\n"),
                    finished: finished, onUpdate: onUpdate)
                await finished.terminateIfPending(
                    SuggestUpdate(status: .kDone), onUpdate: onUpdate)
            } catch {
                await finished.terminateIfPending(
                    SuggestUpdate(status: .kError, error: "\(error)"), onUpdate: onUpdate)
            }
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
            await finished.terminateIfPending(
                SuggestUpdate(status: .kTimeout, error: "timeout \(Int(timeout * 1000))ms"),
                onUpdate: onUpdate)
            streamTask.cancel()
        }
        await streamTask.value
        timeoutTask.cancel()
    }

    private static func readBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var s = ""
        for try await line in bytes.lines { s += line }
        return String(s.prefix(200))
    }

    /// SSE 帧分发：`event: suggestion` → kDelta；`event: done` → kDone（恰好一次终止）。
    private static func dispatch(
        event: String, data: String,
        finished: FinishedFlag, onUpdate: @escaping (SuggestUpdate) -> Void
    ) async {
        guard !event.isEmpty else { return }
        if event == "suggestion" {
            guard let payload = data.data(using: .utf8),
                let cand = try? JSONDecoder().decode(Candidate.self, from: payload) else { return }
            await finished.emitDelta(
                SuggestUpdate(status: .kDelta, candidates: [cand]), onUpdate: onUpdate)
        } else if event == "done" {
            await finished.terminateIfPending(SuggestUpdate(status: .kDone), onUpdate: onUpdate)
        }
    }
}

/// 终止事件恰好一次的守卫（kDelta 之后若已终止则丢弃）。
private actor FinishedFlag {
    private var done = false

    func emitDelta(_ u: SuggestUpdate, onUpdate: @escaping (SuggestUpdate) -> Void) {
        guard !done else { return }
        onUpdate(u)
    }

    func terminateIfPending(_ u: SuggestUpdate, onUpdate: @escaping (SuggestUpdate) -> Void) {
        guard !done else { return }
        done = true
        onUpdate(u)
    }

    func terminate(_ u: SuggestUpdate, onUpdate: @escaping (SuggestUpdate) -> Void) {
        guard !done else { return }
        done = true
        onUpdate(u)
    }
}

// ------------------------------------------------------------ Hub 鉴权（demo/W8 对齐）

/// Hub /v1/auth 最小客户端（register（409 可忽略）→ token），给 suggest 调用取 Bearer。
public enum HubAuth {
    public struct TokenReply: Decodable {
        public let access_token: String
        public let token_type: String
        public let expires_at: Int64
    }

    public static func token(
        baseURL: URL, username: String, password: String,
        session: URLSession = .shared
    ) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/auth/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password,
        ])
        _ = try? await session.data(for: req) // 已注册则 409，忽略

        req = URLRequest(url: baseURL.appendingPathComponent("v1/auth/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username, "password": password,
        ])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(TokenReply.self, from: data).access_token
    }
}
