import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

/// 提词浮层的流式模型（任务书 (c) 的可测试核心）：
/// SuggestClient（Hub SSE / Null 离线双模）流式建议 → **实时刷新**（每帧 Δ 带毫秒时标）→
/// Tab/点按采纳 → `suggestion_feedback` 入库（taken=1）。
///
/// NSPanel 浮层（W12PrompterOverlay）与 CLI 演示（w12ctl prompter）共用本模型，
/// 脚本化实测的「流式刷新演示」即本模型的真实帧流。
public final class W12PrompterModel {
    public struct Frame: Equatable {
        public let seq: Int
        public let elapsedMs: Double
        public let status: StreamStatus
        public let newCandidate: Candidate?
    }

    public private(set) var frames: [Frame] = []
    public private(set) var candidates: [Candidate] = []
    /// 面板实时刷新日志（每帧一行，演示可读：Δ +123ms [2] …）。
    public private(set) var refreshLog: [String] = []
    public private(set) var terminated = false

    private let lock = NSLock()
    private let t0 = Date()

    public init() {}

    /// 跑一轮流式 suggest：若干 kDelta → 恰好一次终止（kDone/kError/kTimeout）；
    /// 每帧 append 刷新日志（实时刷新语义）。终止之后的更新丢弃（SuggestClient 已保证）。
    public func run(
        ctx: SuggestContext, backend: SuggestBackend,
        timeout: TimeInterval = 0.8,
        onFrame: ((Frame) -> Void)? = nil
    ) async {
        await backend.suggest(ctx: ctx, timeout: timeout) { [weak self] update in
            self?.accept(update, onFrame: onFrame)
        }
    }

    private func accept(_ update: SuggestUpdate, onFrame: ((Frame) -> Void)?) {
        lock.lock()
        if terminated {
            lock.unlock()
            return  // 终止后更新丢弃
        }
        let elapsed = Date().timeIntervalSince(t0) * 1000
        var newCand: Candidate? = nil
        if update.status == .kDelta, let c = update.candidates.first {
            candidates.append(contentsOf: update.candidates)
            newCand = c
        }
        if update.status != .kDelta {
            terminated = true
        }
        let frame = Frame(
            seq: frames.count + 1, elapsedMs: elapsed,
            status: update.status, newCandidate: newCand)
        frames.append(frame)
        // 面板刷新日志
        switch update.status {
        case .kDelta:
            if let c = newCand {
                refreshLog.append(String(
                    format: "Δ + %4.0fms [%d] %@  (%.2f %@)",
                    elapsed, candidates.count, c.text, c.score, c.source))
            }
        case .kDone:
            refreshLog.append(String(format: "✓ done +%.0fms（建议刷新完成）", elapsed))
        case .kError:
            refreshLog.append(String(format: "✗ error +%.0fms: %@", elapsed, update.error))
        case .kTimeout:
            refreshLog.append(String(
                format: "⏱ timeout +%.0fms: %@（弃本轮，NFR3）", elapsed, update.error))
        }
        lock.unlock()
        onFrame?(frame)
    }

    /// Tab/点按采纳（默认选中第 index 个，-1 = 第一个）：
    /// **只建议不上屏，采纳才入库**（kind=suggestion_feedback, taken=1）。
    /// 返回采纳的候选（调用方写回客户端上屏）。
    public func adopt(
        index: Int = 0, textIn: String, appId: String?,
        bridge: W12EventBridge = .shared
    ) -> Candidate? {
        lock.lock()
        let list = candidates
        lock.unlock()
        guard !list.isEmpty else { return nil }
        let idx = index < 0 ? 0 : min(index, list.count - 1)
        let chosen = list[idx]
        bridge.reportSuggestionFeedback(
            shown: list.count, taken: 1,
            textIn: textIn, adoptedText: chosen.text, appId: appId)
        return chosen
    }

    /// 浮层渲染（ASCII 快照；NSPanel 用同一数据结构绘制）。
    public func renderPanel(title: String = "⌥Esc 提词浮层") -> String {
        lock.lock()
        let list = candidates
        let log = refreshLog
        lock.unlock()
        var out = "┌─ \(title) ─────────────────────────────┐\n"
        if list.isEmpty {
            out += "│ （流式建议实时刷新中…）                │\n"
        } else {
            for (i, c) in list.enumerated() {
                out += String(format: "│ %d. %@  (%.2f %@)\n", i + 1,
                              padded(c.text, 28), c.score, c.source)
            }
        }
        out += "├─ Tab 采纳 · 数字选中 · Esc 关闭 ─────────┤\n"
        for line in log.suffix(3) {
            out += "│ " + padded(line, 38) + "\n"
        }
        out += "└────────────────────────────────────────┘"
        return out
    }

    private func padded(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}
