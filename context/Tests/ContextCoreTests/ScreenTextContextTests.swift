import XCTest

@testable import ContextCore

/// W27 屏幕文本上下文（ScreenTextContext）与推荐链 SuggestContext.screenText 测试：
/// 截断与拼接策略（单帧头部 400 / 环留 3 帧 / 新→旧拼接 / 总量头部 1200）、
/// /v1/suggest 请求体带 screen_text（智能候选 / ⌥Esc 提词浮层共用请求链）。
final class ScreenTextContextTests: XCTestCase {

    // ------------------------------------------------------------ 截断与拼接策略

    func testPerSnapshotHeadClipWithEllipsis() {
        let long = String(repeating: "屏", count: 500)
        let ctx = ScreenTextContext()
        ctx.noteOCR(long)
        let s = ctx.recentSummary()
        XCTAssertEqual(s.count, ScreenTextContext.perSnapshotChars + 1, "头部 400 + 尾标 …")
        XCTAssertTrue(s.hasSuffix(ScreenTextContext.ellipsis))
        XCTAssertEqual(String(s.prefix(3)), "屏屏屏")
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(ScreenTextContext.normalize("  a \n\n b\tc  "), "a b c")
        XCTAssertEqual(ScreenTextContext.normalize("会议\n\n纪要\n"), "会议 纪要")
    }

    func testRingKeepsLatestThreeNewestFirst() {
        let ctx = ScreenTextContext()
        ctx.noteOCR("frame-one")
        ctx.noteOCR("frame-two")
        ctx.noteOCR("frame-three")
        ctx.noteOCR("frame-four")
        XCTAssertEqual(ctx.count, 3, "环形只留最近 3 帧")
        let s = ctx.recentSummary()
        XCTAssertFalse(s.contains("frame-one"), "最旧帧被挤掉")
        XCTAssertTrue(s.hasPrefix("frame-four"), "新→旧拼接：最新帧在前")
        let idx2 = s.range(of: "frame-two")!.lowerBound
        let idx3 = s.range(of: "frame-three")!.lowerBound
        XCTAssertLessThan(idx3, idx2, "新→旧：four, three, two")
    }

    func testJoinedTotalCapDropsOldestFirst() {
        let ctx = ScreenTextContext()
        // 3 帧各 400 字符 → 拼接 1202 > 1200 → 总量头部截断（尾截断先丢最旧帧内容）
        ctx.noteOCR(String(repeating: "A", count: 400))
        ctx.noteOCR(String(repeating: "B", count: 400))
        ctx.noteOCR(String(repeating: "C", count: 400))
        let s = ctx.recentSummary()
        XCTAssertEqual(s.count, ScreenTextContext.joinedLimit + 1, "总量头部 1200 + 尾标 …")
        XCTAssertEqual(String(s.prefix(400)), String(repeating: "C", count: 400),
                       "最新帧完整在前")
        let aCount = s.filter { $0 == "A" }.count
        XCTAssertLessThan(aCount, 400, "尾截断先丢最旧帧（A）内容（剩 \(aCount)/400）")
        XCTAssertTrue(s.contains(String(repeating: "B", count: 400)), "B 帧完整保留")
    }

    func testClearEmptiesBuffer() {
        let ctx = ScreenTextContext()
        ctx.noteOCR("x")
        XCTAssertEqual(ctx.count, 1)
        ctx.clear()
        XCTAssertEqual(ctx.count, 0)
        XCTAssertEqual(ctx.recentSummary(), "")
    }

    func testEmptyTextNotStored() {
        let ctx = ScreenTextContext()
        ctx.noteOCR("")
        ctx.noteOCR("   \n  ")
        XCTAssertEqual(ctx.count, 0)
    }

    // ------------------------------------------------------------ SuggestContext.screenText

    func testSuggestContextCarriesScreenText() {
        let ctx = SuggestContext(
            beforeCursor: "开会", appId: "com.apple.TextEdit",
            fromVoice: true, contextDigest: "d", screenText: "近期 OCR 摘要")
        XCTAssertEqual(ctx.screenText, "近期 OCR 摘要")
        let empty = SuggestContext(beforeCursor: "")
        XCTAssertEqual(empty.screenText, "", "默认空串（C1 默认关）")
    }

    func testHubRequestBodyIncludesScreenText() {
        let ctx = SuggestContext(
            beforeCursor: "ni hao", appId: "com.apple.TextEdit",
            fromVoice: false, contextDigest: "sha256:x", screenText: "屏上有个会议纪要")
        let body = HubSuggestBackend.requestBody(ctx)
        XCTAssertEqual(body["screen_text"] as? String, "屏上有个会议纪要")
        XCTAssertEqual(body["before_cursor"] as? String, "ni hao")
        XCTAssertEqual(body["app_id"] as? String, "com.apple.TextEdit")
        XCTAssertEqual(body["context_digest"] as? String, "sha256:x")
        // 空串也带键（契约稳定）
        let emptyBody = HubSuggestBackend.requestBody(SuggestContext(beforeCursor: "x"))
        XCTAssertEqual(emptyBody["screen_text"] as? String, "")
    }
}
