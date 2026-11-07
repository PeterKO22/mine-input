import ContextCore
import Foundation
import XCTest

@testable import MemoryCore

/// W27 屏幕上下文进记忆层「情境」测试：situation.screen_text（§15.1 W27 扩展键）
/// round-trip / 缺省省略 / 配对注入（仅 c1 记录）/ 一键清空联动（含屏幕上下文环）。
final class MemoryScreenTextTests: XCTestCase {
    var memDir: String!
    var dbPath: String!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "w27-\(UUID().uuidString)"
        memDir = base + "/memory"
        dbPath = base + "/interaction.db"
    }

    override func tearDown() {
        ScreenTextContext.shared.clear()
        try? FileManager.default.removeItem(
            atPath: (memDir as NSString).deletingLastPathComponent)
        super.tearDown()
    }

    func testScreenTextRoundTripInSituation() throws {
        let rec = MemoryRecord(
            tsMs: 1_762_500_000_000,
            situation: Situation(
                beforeCursor: "开会",
                ocrDigest: "sha256:ab len:9",
                screenText: "屏幕上有个会议纪要",
                thread: []),
            myReply: MyReply(text: "收到", mode: .text),
            meta: Meta(sessionId: "s-1"),
            consent: .c1)
        let line = try rec.jsonLine()
        XCTAssertTrue(line.contains("\"screen_text\":\"屏幕上有个会议纪要\""), line)
        let back = MemoryRecord.decode(line: line)
        XCTAssertEqual(back?.situation.screenText, "屏幕上有个会议纪要")

        // 缺省省略（C1 默认 NULL → 键不出现，旧行为不漂移）
        let plain = MemoryRecord(
            tsMs: 1,
            situation: Situation(beforeCursor: "x"),
            myReply: MyReply(text: "y"),
            meta: Meta())
        XCTAssertFalse(try plain.jsonLine().contains("screen_text"))
    }

    func testPairingAttachesScreenTextOnlyToC1Records() {
        let ocrEv = InteractionEvent(
            ts: 1000, deviceId: "mac", appId: "com.apple.TextEdit",
            kind: .keySession, textIn: "ni hao", textOut: "你好",
            ocrDigest: "sha256:a len:3")
        let plainEv = InteractionEvent(
            ts: 40_000, deviceId: "mac", appId: "com.apple.TextEdit",
            kind: .keySession, textIn: "zai", textOut: "在")
        let out = MemoryPairing.pair(
            events: [ocrEv, plainEv],
            screenText: "近期 OCR 摘要")
        XCTAssertEqual(out.memories.count, 2)
        let c1 = out.memories.first { $0.consent == .c1 }
        let c0 = out.memories.first { $0.consent == .c0 }
        XCTAssertEqual(c1?.situation.screenText, "近期 OCR 摘要", "c1 记录附屏幕上下文")
        XCTAssertNil(c0?.situation.screenText, "c0 记录绝不附屏幕上下文")
    }

    func testPairingWithoutScreenTextKeepsNil() {
        let ev = InteractionEvent(
            ts: 1000, deviceId: "mac", appId: "com.apple.TextEdit",
            kind: .keySession, textIn: "x", textOut: "y", ocrDigest: "sha256:a len:3")
        let out = MemoryPairing.pair(events: [ev])
        XCTAssertNil(out.memories.first?.situation.screenText, "未注入 → nil（缺省省略）")
    }

    func testQueryKeywordHitsScreenText() throws {
        let memory = MemoryStore(rootDir: memDir)
        memory.append(MemoryRecord(
            tsMs: 1_762_500_000_000,
            situation: Situation(beforeCursor: "普通", screenText: "屏上项目周报"),
            myReply: MyReply(text: "好"),
            meta: Meta(sessionId: "s-1")))
        XCTAssertEqual(memory.query(keyword: "项目周报").count, 1, "检索命中 screen_text")
    }

    func testClearAllAlsoClearsScreenTextContextRing() throws {
        let store = try InteractionStore(path: dbPath)
        let memory = MemoryStore(rootDir: memDir, interactionStore: store)
        ScreenTextContext.shared.noteOCR("屏幕残留内容")
        XCTAssertEqual(ScreenTextContext.shared.count, 1)
        _ = MemoryPrivacy.clearAll(memory: memory, events: store)
        XCTAssertEqual(ScreenTextContext.shared.count, 0,
                       "一键清空（含记忆层）→ 屏幕上下文环同清（清空即失忆）")
    }
}
