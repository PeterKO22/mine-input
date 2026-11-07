import Foundation

/// 屏幕文本上下文存储（W27）——「按键/语音 → 读屏 → 理解与推荐」环的上下文侧：
/// C1 采集轮的 OCR 全文摘要化后进本环形缓冲（**仅内存**，不落盘），供
///   ① 推荐链（SuggestContext.screenText：智能候选 / ⌥Esc 提词浮层请求链）；
///   ② 记忆层 JSONL「情境」（situation.screen_text，本地记忆）。
///
/// 截断与拼接策略（**唯一规格源**，单测断言防漂移）：
///   1. **单帧截断**：每帧 OCR 文本先压空白（连续空白/换行 → 单空格）再取**头部**
///      `perSnapshotChars`（默认 400）字符，超长补 `…` 尾标（屏幕文本无固定阅读
///      顺序，保头部 = 保屏幕上部/标题区，最稳定）；
///   2. **环形保留**：只留最近 `maxSnapshots`（默认 3）帧，新帧挤掉最旧帧
///      （近期 OCR 摘要 = 最近几帧，不做跨帧全文累积）；
///   3. **拼接**：**新 → 旧**（最新帧在前，最相关在前），帧间以 `\n` 分隔；
///   4. **总量截断**：拼接结果再取**头部** `joinedLimit`（默认 1200）字符，
///      超长补 `…`（新帧在前 → 尾截断先丢最旧帧内容）；
///   5. 清空即失忆：`clear()` 一键清空（⌥M 一键清空 / C1 关闭 / 熔断联动调用）。
///
/// 隐私红线（用户既定契约）：屏幕文本**只进本地上下文/记忆与本地/自建 Hub**，
/// 绝不上报第三方（无遥测）；密码框零采集（上游 W12C1Collector 门禁，本类不收）；
/// C1 默认关，显式同意后才会有帧进来。
public final class ScreenTextContext {
    public static let shared = ScreenTextContext()

    /// 单帧截断上限（字符）。
    public static let perSnapshotChars = 400
    /// 环形保留帧数。
    public static let maxSnapshots = 3
    /// 拼接总量截断上限（字符）。
    public static let joinedLimit = 1200
    /// 帧间分隔符。
    public static let separator = "\n"
    /// 截断尾标。
    public static let ellipsis = "…"

    private let lock = NSLock()
    /// 旧 → 新（append 新帧；超容量丢最旧）。
    private var snapshots: [String] = []

    public init() {}

    /// 帧数（诊断/状态显示用）。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return snapshots.count
    }

    /// 一帧 OCR 全文入环（策略 1/2：单帧截断 + 环形保留）。空文本不入环。
    public func noteOCR(_ text: String) {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return }
        let clipped = Self.clip(normalized, limit: Self.perSnapshotChars)
        lock.lock()
        snapshots.append(clipped)
        if snapshots.count > Self.maxSnapshots {
            snapshots.removeFirst(snapshots.count - Self.maxSnapshots)
        }
        lock.unlock()
    }

    /// 近期 OCR 摘要（策略 3/4：新→旧拼接 + 总量截断）。无帧时返回空串。
    public func recentSummary() -> String {
        lock.lock()
        let joined = snapshots.reversed().joined(separator: Self.separator)
        lock.unlock()
        guard !joined.isEmpty else { return "" }
        return Self.clip(joined, limit: Self.joinedLimit)
    }

    /// 一键清空（清空即失忆）。
    public func clear() {
        lock.lock()
        snapshots.removeAll()
        lock.unlock()
    }

    // ------------------------------------------------------------ 策略纯函数（可单测）

    /// 压空白：连续空白/换行 → 单空格，首尾去空白。
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+", with: " ",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 头部截断 + 超长尾标。
    public static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + ellipsis
    }
}
