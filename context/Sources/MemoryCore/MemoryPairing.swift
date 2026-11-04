import ContextCore
import Foundation

/// 情境→回复 配对（§15.1 配对规则）：从 W9 事件流（InteractionStore `events`）配对记忆。
///
/// 配对规则（一次输入会话 = 一条记忆；取消不记）：
/// 1. **输入会话** = 事件流中同 `app_id`、相邻间隔 ≤ `sessionGapMs` 的连续事件段
///    （W9 语义：一次输入会话的上下文捕获→若干增量/候选/建议事件→止于上屏/取消）；
/// 2. **上屏（commit）** = 段内存在 `text_out` 非空事件（W9：上屏文本），
///    最后一个上屏事件的 `text_out` 即「我回了什么话」（my_reply）；
/// 3. **取消不记**：段内无任何上屏（text_out 全空）= 取消/未上屏 → 不生成记忆；
/// 4. 情境（situation）：`before_cursor` 取段首事件 `text_in`（上下文捕获）；
///    ocr/asr 摘要取段内首个非空（C1，仅摘要）；thread 由同 app 前序已记忆回合回填
///    （["对方:{前行情境}","我:{前情回复}"]，MVP 近似——对方侧文本取自当时输入框上下文）；
/// 5. meta：`session_id` 由会话首尾 ts+app 确定性生成（配对重放幂等去重用）；
///    `from_suggestion` = 段内 suggestion_feedback（taken≥1）的事件标识，否则空串；
///    `confidence` 事件流无置信度字段，恒 0.0（待 suggest 分数回填）；
/// 6. consent：段内含 C1 摘要 → c1，否则 c0。
public enum MemoryPairing {
    public struct Options {
        /// 同一会话的最大事件间隔（毫秒）。
        public var sessionGapMs: Int64 = 30_000
        /// thread 回填深度（前序回合数）。
        public var threadDepth: Int = 4
        /// 记忆 device 字段（§15.1："mac"）。
        public var device: String = "mac"
        public init() {}
    }

    public struct Outcome {
        /// 生成的记忆（时间正序）。
        public var memories: [MemoryRecord]
        /// 事件流里识别出的输入会话总数。
        public var sessionCount: Int
        /// 取消/未上屏（不记）的会话数。
        public var cancelledCount: Int
    }

    /// 纯函数：事件流 → 记忆（不落盘；落盘交给 MemoryStore.append，熔断/清空/编辑同样管辖）。
    public static func pair(
        events: [InteractionEvent],
        options: Options = Options()
    ) -> Outcome {
        // 时间正序（稳定）；事件流按 ts 索引即天然有序。
        let sorted = events.enumerated()
            .sorted { a, b in
                a.element.ts != b.element.ts ? a.element.ts < b.element.ts : a.offset < b.offset
            }
            .map { $0.element }

        // 1) 会话切分：同 app + 间隔 ≤ sessionGapMs。
        var sessions: [[InteractionEvent]] = []
        for ev in sorted {
            if var last = sessions.last,
                let prev = last.last,
                prev.appId == ev.appId,
                ev.ts - prev.ts <= options.sessionGapMs {
                last.append(ev)
                sessions[sessions.count - 1] = last
            } else {
                sessions.append([ev])
            }
        }

        var memories: [MemoryRecord] = []
        var cancelled = 0
        // thread 回填：同 app 的前序已记忆回合（对方:{情境} / 我:{回复}）。
        var history: [String: [(situation: String, reply: String)]] = [:]

        for session in sessions {
            guard let first = session.first else { continue }

            // 2) 上屏判定（取消不记）。
            let committed = session.filter { !$0.textOut.isEmpty }
            guard let commit = committed.last else {
                cancelled += 1
                continue
            }

            // 情境：段首上下文捕获。
            let beforeCursor = first.textIn.isEmpty
                ? (session.first(where: { !$0.textIn.isEmpty })?.textIn ?? "")
                : first.textIn
            let ocr = session.compactMap { $0.ocrDigest }.first
            let asr = session.compactMap { $0.asrDigest }.first

            // meta.from_suggestion：段内已采纳建议（taken≥1）的事件标识。
            let sug = session.first {
                $0.kind == .suggestionFeedback && ($0.suggestionTaken ?? 0) >= 1
            }
            let fromSuggestion = sug.map { "suggestion_feedback:\($0.ts)" } ?? ""

            // thread：同 app 前序回合。
            let prior = history[first.appId] ?? []
            var thread: [String] = []
            for turn in prior.suffix(options.threadDepth) {
                if !turn.situation.isEmpty { thread.append("对方:\(turn.situation)") }
                if !turn.reply.isEmpty { thread.append("我:\(turn.reply)") }
            }

            // 5) 确定性 session_id（配对重放幂等）。
            let sessionId = "\(first.ts)-\(commit.ts)-\(first.appId)"

            let rec = MemoryRecord(
                tsMs: commit.ts,
                device: options.device,
                appId: first.appId,
                situation: Situation(
                    beforeCursor: beforeCursor,
                    screenDigest: nil,
                    ocrDigest: ocr,
                    asrDigest: asr,
                    thread: thread),
                myReply: MyReply(
                    text: commit.textOut,
                    mode: session.contains { $0.kind == .voiceSession } ? .voice : .text),
                meta: Meta(
                    fromSuggestion: fromSuggestion,
                    confidence: 0.0,
                    sessionId: sessionId),
                consent: (ocr != nil || asr != nil) ? .c1 : .c0)
            memories.append(rec)

            var h = history[first.appId] ?? []
            h.append((situation: beforeCursor, reply: commit.textOut))
            history[first.appId] = h
        }

        return Outcome(
            memories: memories,
            sessionCount: sessions.count,
            cancelledCount: cancelled)
    }
}
