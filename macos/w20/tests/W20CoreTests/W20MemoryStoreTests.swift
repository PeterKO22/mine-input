// W20MemoryStoreTests.swift — 记忆管理数据层单测（N8，脚本化可验部分）
//
// 按 §15.1 schema 构造 JSONL fixture，验证：按日分组加载 / 检索（keyword/app/since）/
// 编辑（重写当日文件，未改动行原样保留）/ 删除（物理移除该行）/ 导出。
import XCTest
@testable import W20Core

final class W20MemoryStoreTests: XCTestCase {
    var dir: URL!
    var store: W20MemoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w20-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = W20MemoryStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fixture() -> String {
        """
        {"id":"m-1","ts":"2026-11-03T09:00:00+08:00","device":"mac","app_id":"com.apple.mail","situation":{"before_cursor":"好的，我","screen_digest":"sha256:aaa len:10","thread":["对方:明天开会吗","我:开的"]},"my_reply":{"text":"开的，明天十点","mode":"text"},"meta":{"from_suggestion":"prop-9|","confidence":0.8,"session_id":"s1"},"consent":"c1"}
        {"id":"m-2","ts":"2026-11-03T10:00:00+08:00","device":"mac","app_id":"com.tencent.xinWeChat","situation":{"before_cursor":"收到","thread":["对方:文件发我一下"]},"my_reply":{"text":"稍等","mode":"voice"},"meta":{"confidence":0.5},"consent":"c0"}
        {"id":"m-3","ts":"2026-11-04T08:30:00+08:00","device":"mac","app_id":"com.apple.mail","situation":{"before_cursor":"关于报价","thread":[]},"my_reply":{"text":"报价单见附件","mode":"text"},"consent":"c1"}
        """
    }

    private func writeFixture() throws {
        let lines = fixture().split(separator: "\n")
        // m-1、m-2 → 2026-11-03；m-3 → 2026-11-04（与各自行 ts 对应）
        try (String(lines[0]) + "\n" + String(lines[1]) + "\n").write(
            to: dir.appendingPathComponent("2026-11-03.jsonl"),
            atomically: true, encoding: .utf8)
        try (String(lines[2]) + "\n").write(
            to: dir.appendingPathComponent("2026-11-04.jsonl"),
            atomically: true, encoding: .utf8)
    }

    func testLoadGroupedByDay() throws {
        try writeFixture()
        XCTAssertEqual(store.days(), ["2026-11-04", "2026-11-03"])
        XCTAssertEqual(store.entries(day: "2026-11-03").count, 2)
        XCTAssertEqual(store.entries(day: "2026-11-04").count, 1)
        XCTAssertEqual(store.allEntries().count, 3)
        let e = store.find(id: "m-1")?.entry
        XCTAssertEqual(e?.situation?.beforeCursor, "好的，我")
        XCTAssertEqual(e?.situation?.thread?.count, 2)
        XCTAssertEqual(e?.myReply?.text, "开的，明天十点")
        XCTAssertEqual(e?.meta?.fromSuggestion, "prop-9|")
    }

    func testSearchKeywordAppSince() throws {
        try writeFixture()
        XCTAssertEqual(store.search(keyword: "报价").map(\.id), ["m-3"])
        XCTAssertEqual(store.search(keyword: "稍等").map(\.id), ["m-2"])
        XCTAssertEqual(store.search(keyword: "文件发我").map(\.id), ["m-2"])  // thread 命中
        XCTAssertEqual(store.search(app: "com.apple.mail").map(\.id).sorted(),
                       ["m-1", "m-3"])
        XCTAssertEqual(store.search(since: "2026-11-04").map(\.id), ["m-3"])
        XCTAssertEqual(store.search(keyword: "不存在词"), [])
    }

    func testUpdateSituationAndReply() throws {
        try writeFixture()
        let before2 = try String(contentsOf: dir.appendingPathComponent("2026-11-03.jsonl"),
                                 encoding: .utf8)
        XCTAssertTrue(store.update(id: "m-2", beforeCursor: "改后情境",
                                   thread: ["对方:新线程"], replyText: "改后回复"))
        let e = store.find(id: "m-2")!.entry
        XCTAssertEqual(e.situation?.beforeCursor, "改后情境")
        XCTAssertEqual(e.situation?.thread, ["对方:新线程"])
        XCTAssertEqual(e.myReply?.text, "改后回复")
        // 未提及字段保留（mode 等），未改动行（m-1）原样保留
        XCTAssertEqual(e.myReply?.mode, "voice")
        let after = try String(contentsOf: dir.appendingPathComponent("2026-11-03.jsonl"),
                               encoding: .utf8)
        let m1Before = before2.split(separator: "\n").first!
        let m1After = after.split(separator: "\n").first!
        XCTAssertEqual(m1Before, m1After)  // 未改动的行字节级原样
        XCTAssertFalse(store.update(id: "no-such-id", replyText: "x"))
    }

    func testDeletePhysicallyRemovesLine() throws {
        try writeFixture()
        XCTAssertTrue(store.delete(id: "m-1"))
        XCTAssertNil(store.find(id: "m-1"))
        XCTAssertEqual(store.entries(day: "2026-11-03").map(\.id), ["m-2"])
        XCTAssertTrue(store.delete(id: "m-2"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("2026-11-03.jsonl").path),
            "空日文件应移除")
        XCTAssertEqual(store.allEntries().map(\.id), ["m-3"])
    }

    func testExportJSONL() throws {
        try writeFixture()
        let out = dir.appendingPathComponent("export.jsonl")
        try store.export(entries: store.search(app: "com.apple.mail"), to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(
                with: line.data(using: .utf8)!) as! [String: Any]
            XCTAssertNotNil(obj["id"])
            XCTAssertNotNil(obj["situation"])
        }
    }

    func testCollectionStatusAndBreaker() throws {
        try writeFixture()
        final class MockBreaker: W20BreakerControl {
            var isTripped = false
            func trip() { isTripped = true }
            func reset() { isTripped = false }
        }
        let breaker = MockBreaker()
        var s = store.collectionStatus(breaker: breaker)
        XCTAssertEqual(s.totalCount, 3)
        XCTAssertFalse(s.breakerTripped)
        XCTAssertEqual(s.label, "采集中")
        breaker.trip()
        s = store.collectionStatus(breaker: breaker)
        XCTAssertTrue(s.breakerTripped)
        XCTAssertEqual(s.label, "已熔断（停采集）")
    }

    func testLenientParsingSkipsBadLines() throws {
        try ("{broken json\n" + fixture().split(separator: "\n").first! + "\n")
            .write(to: dir.appendingPathComponent("2026-11-03.jsonl"),
                   atomically: true, encoding: .utf8)
        XCTAssertEqual(store.entries(day: "2026-11-03").map(\.id), ["m-1"])
    }
}
