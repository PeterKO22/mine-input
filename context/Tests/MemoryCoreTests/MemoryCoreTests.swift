import ContextCore
import Foundation
import XCTest

@testable import MemoryCore

/// W19 memory-jsonl 测试：§15.1 schema、配对规则、落盘/检索/编辑/删除/清空、隐私联动、同步挂钩。
final class MemoryCoreTests: XCTestCase {
    var memDir: String!
    var dbPath: String!

    override func setUp() {
        super.setUp()
        let base = NSTemporaryDirectory() + "w19-\(UUID().uuidString)"
        memDir = base + "/memory"
        dbPath = base + "/interaction.db"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            atPath: (memDir as NSString).deletingLastPathComponent)
        super.tearDown()
    }

    // ------------------------------------------------------------ 工具

    func makeRecord(
        tsMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        appId: String = "com.apple.TextEdit",
        before: String = "情境",
        reply: String = "回复",
        mode: MyReply.Mode = .text,
        thread: [String] = [],
        ocr: String? = nil,
        asr: String? = nil,
        sessionId: String = "s-1"
    ) -> MemoryRecord {
        MemoryRecord(
            tsMs: tsMs,
            appId: appId,
            situation: Situation(
                beforeCursor: before, ocrDigest: ocr, asrDigest: asr, thread: thread),
            myReply: MyReply(text: reply, mode: mode),
            meta: Meta(sessionId: sessionId))
    }

    func dayFileContents() -> String {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: memDir)) ?? []).sorted()
        return names.compactMap {
            try? String(contentsOfFile: memDir + "/" + $0, encoding: .utf8)
        }.joined()
    }

    // ------------------------------------------------------------ (0) §15.1 schema

    func testSchemaMatchesSpec151() throws {
        let rec = MemoryRecord(
            ts: "2026-11-04T12:00:00.000Z",
            device: "mac",
            appId: "com.apple.TextEdit",
            situation: Situation(
                beforeCursor: "对方:明天的会改到10点",
                screenDigest: "sha256:abc len:12",
                ocrDigest: nil, asrDigest: nil,
                thread: ["对方:明天的会改到10点", "我:收到，我会准时到"]),
            myReply: MyReply(text: "收到，我会准时到", mode: .text),
            meta: Meta(fromSuggestion: "", confidence: 0.0, sessionId: "s-42"),
            consent: .c1)
        let obj = try JSONSerialization.jsonObject(
            with: try rec.jsonLine().data(using: .utf8)!) as! [String: Any]

        // 顶层键与 §15.1 逐字一致
        XCTAssertEqual(
            Set(obj.keys),
            Set(["id", "ts", "device", "app_id", "situation", "my_reply", "meta", "consent"]))
        XCTAssertEqual(obj["ts"] as? String, "2026-11-04T12:00:00.000Z")
        XCTAssertEqual(obj["device"] as? String, "mac")
        XCTAssertEqual(obj["app_id"] as? String, "com.apple.TextEdit")
        XCTAssertEqual(obj["consent"] as? String, "c1")

        let sit = obj["situation"] as! [String: Any]
        XCTAssertEqual(
            Set(sit.keys),
            Set(["before_cursor", "screen_digest", "thread"])) // ocr/asr 摘要缺省（C1 默认 NULL）→ 省略
        XCTAssertEqual(sit["before_cursor"] as? String, "对方:明天的会改到10点")
        XCTAssertEqual(sit["screen_digest"] as? String, "sha256:abc len:12")
        XCTAssertEqual(sit["thread"] as? [String], ["对方:明天的会改到10点", "我:收到，我会准时到"])

        // C1 摘要在场时 situation 五键齐全（§15.1）
        let c1 = MemoryRecord(
            ts: "2026-11-04T12:00:00.000Z",
            situation: Situation(
                beforeCursor: "x", screenDigest: "sha256:s len:9",
                ocrDigest: "sha256:o len:1", asrDigest: "sha256:a len:2"),
            myReply: MyReply(text: "y"), meta: Meta())
        let c1Obj = try JSONSerialization.jsonObject(
            with: try c1.jsonLine().data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(
            Set((c1Obj["situation"] as! [String: Any]).keys),
            Set(["before_cursor", "screen_digest", "ocr_digest", "asr_digest", "thread"]))

        let rep = obj["my_reply"] as! [String: Any]
        XCTAssertEqual(Set(rep.keys), Set(["text", "mode"]))
        XCTAssertEqual(rep["text"] as? String, "收到，我会准时到")
        XCTAssertEqual(rep["mode"] as? String, "text")

        let meta = obj["meta"] as! [String: Any]
        XCTAssertEqual(Set(meta.keys), Set(["from_suggestion", "confidence", "session_id"]))
        XCTAssertEqual(meta["confidence"] as? Double, 0.0)
        XCTAssertEqual(meta["session_id"] as? String, "s-42")

        // voice 枚举值
        let v = MemoryRecord(
            ts: "2026-11-04T12:00:00.000Z",
            situation: Situation(), myReply: MyReply(text: "x", mode: .voice),
            meta: Meta())
        let vObj = try JSONSerialization.jsonObject(
            with: try v.jsonLine().data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual((vObj["my_reply"] as! [String: Any])["mode"] as? String, "voice")

        // 往返
        let back = MemoryRecord.decode(line: try rec.jsonLine())
        XCTAssertEqual(back, rec)
    }

    func testTsMsAndDayKey() {
        let rec = makeRecord(tsMs: 1_793_730_973_174)
        XCTAssertEqual(rec.tsMs, 1_793_730_973_174)
        XCTAssertEqual(
            rec.dayKey(),
            MemoryRecord.dayKey(fromMs: 1_793_730_973_174, timeZone: .current))
    }

    // ------------------------------------------------------------ (a) 配对：一次输入会话=一条记忆，取消不记

    func testPairingOneSessionOneMemoryAndCancelNotRecorded() {
        let base: Int64 = 1_793_730_973_000
        let events = [
            // 会话 1（打字，上屏）
            InteractionEvent(
                ts: base, deviceId: "mac-d", appId: "com.apple.TextEdit",
                kind: .keySession,
                textIn: "明天的会改到10点", textOut: "收到，我会准时到"),
            // 会话 2（语音：增量 + 建议采纳上屏 → 同一会话）
            InteractionEvent(
                ts: base + 60_000, deviceId: "mac-d", appId: "com.apple.TextEdit",
                kind: .voiceSession, textIn: "今天下午有空吗", textOut: ""),
            InteractionEvent(
                ts: base + 61_000, deviceId: "mac-d", appId: "com.apple.TextEdit",
                kind: .suggestionFeedback, textIn: "今天下午",
                textOut: "今天下午有空，我们见一面", suggestionShown: 3, suggestionTaken: 1),
            // 会话 3（取消：无上屏 → 不记）
            InteractionEvent(
                ts: base + 120_000, deviceId: "mac-d", appId: "com.apple.TextEdit",
                kind: .keySession, textIn: "这句取消", textOut: ""),
            // 会话 4（换 app，上屏）
            InteractionEvent(
                ts: base + 180_000, deviceId: "mac-d", appId: "com.tencent.xinWeChat",
                kind: .keySession, textIn: "晚上一起吃饭", textOut: "好的晚上见"),
        ]
        let out = MemoryPairing.pair(events: events)

        XCTAssertEqual(out.sessionCount, 4)
        XCTAssertEqual(out.cancelledCount, 1) // 取消不记
        XCTAssertEqual(out.memories.count, 3)

        let m1 = out.memories[0]
        XCTAssertEqual(m1.situation.beforeCursor, "明天的会改到10点")
        XCTAssertEqual(m1.myReply.text, "收到，我会准时到")
        XCTAssertEqual(m1.myReply.mode, .text)
        XCTAssertTrue(m1.situation.thread.isEmpty)
        XCTAssertEqual(m1.consent, .c0)
        XCTAssertEqual(m1.meta.confidence, 0.0)

        let m2 = out.memories[1]
        // 会话 2：段首上下文 + 段内最后上屏为回复 + 语音模式 + 建议来源
        XCTAssertEqual(m2.situation.beforeCursor, "今天下午有空吗")
        XCTAssertEqual(m2.myReply.text, "今天下午有空，我们见一面")
        XCTAssertEqual(m2.myReply.mode, .voice)
        XCTAssertEqual(m2.meta.fromSuggestion, "suggestion_feedback:\(base + 61_000)")
        // thread 由同 app 前序回合回填（对方:{情境} / 我:{回复}）
        XCTAssertEqual(m2.situation.thread, ["对方:明天的会改到10点", "我:收到，我会准时到"])

        // 会话 4（换 app）：thread 不含别 app 的回合
        XCTAssertTrue(out.memories[2].situation.thread.isEmpty)
        XCTAssertEqual(out.memories[2].appId, "com.tencent.xinWeChat")
    }

    func testPairingDeterministicSessionIdAndC1Consent() {
        let base: Int64 = 1_793_731_000_000
        let events = [
            InteractionEvent(
                ts: base, deviceId: "mac-d", appId: "com.apple.Notes",
                kind: .keySession, textIn: "会议纪要", textOut: "已记录",
                ocrDigest: "sha256:deadbeef len:120"),
        ]
        let a = MemoryPairing.pair(events: events)
        let b = MemoryPairing.pair(events: events)
        XCTAssertEqual(a.memories.map { $0.meta.sessionId }, b.memories.map { $0.meta.sessionId })
        XCTAssertEqual(a.memories[0].consent, .c1) // 含 C1 摘要 → c1
        XCTAssertEqual(a.memories[0].situation.ocrDigest, "sha256:deadbeef len:120")
    }

    // ------------------------------------------------------------ (a) 落盘：append JSONL 到当日文件

    func testAppendWritesDayJSONL() throws {
        let store = MemoryStore(rootDir: memDir)
        let rec = makeRecord(before: "落盘情境", reply: "落盘回复")
        guard case .appended(let id) = store.append(rec) else {
            return XCTFail("append refused")
        }
        XCTAssertEqual(id, rec.id)

        let expectedDay = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let path = memDir + "/" + expectedDay + ".jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "当日文件应为 \(expectedDay).jsonl")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertEqual(MemoryRecord.decode(line: String(text.split(separator: "\n")[0])), rec)
    }

    // ------------------------------------------------------------ (b) 检索 query/recent

    func testQueryKeywordAppSinceAndRecent() throws {
        let store = MemoryStore(rootDir: memDir)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let old = now - 10 * 24 * 3600 * 1000
        store.append(makeRecord(tsMs: now, appId: "com.apple.TextEdit",
            before: "明天的会改到10点", reply: "收到，我会准时回复", sessionId: "s-now"))
        store.append(makeRecord(tsMs: now - 3600_000, appId: "com.tencent.xinWeChat",
            before: "晚上一起吃饭", reply: "好的晚上见", sessionId: "s-wx"))
        store.append(makeRecord(tsMs: old, appId: "com.apple.TextEdit",
            before: "十天前的话题", reply: "十天前的回复", sessionId: "s-old"))

        // --keyword 命中（回复侧）
        let hit = store.query(keyword: "准时")
        XCTAssertEqual(hit.map { $0.meta.sessionId }, ["s-now"])
        // --keyword 情境侧
        XCTAssertEqual(store.query(keyword: "吃饭").map { $0.meta.sessionId }, ["s-wx"])
        // --app
        XCTAssertEqual(
            store.query(app: "xinWeChat").map { $0.meta.sessionId }, ["s-wx"])
        // --since
        XCTAssertEqual(
            store.query(since: Date(timeIntervalSince1970: Double(now) / 1000 - 7 * 24 * 3600))
                .map { $0.meta.sessionId }, ["s-now", "s-wx"])
        // 组合 + 无命中
        XCTAssertTrue(store.query(keyword: "不存在的词").isEmpty)
        XCTAssertEqual(store.query(keyword: "回复", app: "TextEdit").count, 2)

        // recent（时间倒序）
        XCTAssertEqual(store.recent(2).map { $0.meta.sessionId }, ["s-now", "s-wx"])
    }

    func testRecentForSuggestContext() {
        let store = MemoryStore(rootDir: memDir)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.append(makeRecord(tsMs: now - 1000, before: "情境A", reply: "回复A", sessionId: "s-a"))
        store.append(makeRecord(tsMs: now, before: "情境B", reply: "回复B", sessionId: "s-b"))
        let lines = store.recentForSuggest(5)
        XCTAssertEqual(lines.count, 2)
        // 注入顺序：旧→新
        XCTAssertTrue(lines[0].contains("情境A") && lines[0].contains("回复A"))
        XCTAssertTrue(lines[1].contains("情境B") && lines[1].contains("回复B"))
    }

    // ------------------------------------------------------------ (c) 手工编辑（重写当日文件）/ 删除（物理移除行）

    func testEditRewritesDayFile() throws {
        let store = MemoryStore(rootDir: memDir)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.append(makeRecord(tsMs: now, before: "原情境", reply: "原回复", sessionId: "s-1"))
        store.append(makeRecord(tsMs: now + 1, before: "别动我", reply: "别动的回复", sessionId: "s-2"))

        let updated = try store.edit(id: store.query(limit: 10).first { $0.meta.sessionId == "s-1" }!.id,
            beforeCursor: "改后情境", replyText: "改后回复")
        XCTAssertEqual(updated.situation.beforeCursor, "改后情境")
        XCTAssertEqual(updated.myReply.text, "改后回复")

        // 当日文件已重写：2 行（改的行 + 未动的行原样）
        let lines = dayFileContents().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let recs = lines.compactMap(MemoryRecord.decode)
        XCTAssertEqual(recs.count, 2)
        XCTAssertTrue(recs.contains { $0.meta.sessionId == "s-1" && $0.myReply.text == "改后回复" })
        XCTAssertTrue(recs.contains { $0.meta.sessionId == "s-2" && $0.myReply.text == "别动的回复" })
    }

    func testDeletePhysicallyRemovesLine() throws {
        let store = MemoryStore(rootDir: memDir)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.append(makeRecord(tsMs: now, reply: "留下的", sessionId: "s-keep"))
        store.append(makeRecord(tsMs: now + 1, reply: "删掉的", sessionId: "s-gone"))
        let target = store.query(limit: 10).first { $0.meta.sessionId == "s-gone" }!

        let removed = try store.delete(id: target.id)
        XCTAssertEqual(removed.myReply.text, "删掉的")

        // 物理移除：文件行数 -1，原文行不存在（无 tombstone）
        let text = dayFileContents()
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertFalse(text.contains("删掉的"))
        XCTAssertTrue(text.contains("留下的"))
        XCTAssertThrowsError(try store.delete(id: target.id)) // 二次删除 → notFound
        XCTAssertTrue(store.query(keyword: "删掉的").isEmpty) // 撤回停传：导出/同步同源
    }

    // ------------------------------------------------------------ (c) 隐私联动：熔断停记 / 一键清空同清

    func testBreakerStopsMemoryRecording() throws {
        let store = try InteractionStore(path: dbPath)
        let breaker = CircuitBreaker(store: store)
        let memory = MemoryStore(rootDir: memDir, interactionStore: store)

        guard case .appended = memory.append(makeRecord(sessionId: "s-before")) else {
            return XCTFail("熔断前应可记")
        }
        breaker.trip() // 一键熔断
        let res = memory.append(makeRecord(sessionId: "s-after"))
        XCTAssertEqual(res, .refused(.breakerTripped)) // 熔断停记
        XCTAssertEqual(memory.count(), 1) // 记忆保留不新增

        breaker.reset()
        guard case .appended = memory.append(makeRecord(sessionId: "s-resumed")) else {
            return XCTFail("熔断恢复后应可记")
        }
        XCTAssertEqual(memory.count(), 2)
    }

    func testClearAllEventsAndMemoryTogether() throws {
        let store = try InteractionStore(path: dbPath)
        store.insert(InteractionEvent(deviceId: "mac-d", kind: .keySession, textIn: "x", textOut: "y"))
        let memory = MemoryStore(rootDir: memDir, interactionStore: store)
        memory.append(makeRecord(sessionId: "s-1"))
        memory.append(makeRecord(sessionId: "s-2"))
        XCTAssertEqual(memory.count(), 2)
        XCTAssertEqual(store.count(), 1)

        let (m, e) = MemoryPrivacy.clearAll(memory: memory, events: store)
        XCTAssertEqual(m, 2)
        XCTAssertEqual(e, 1)
        XCTAssertEqual(memory.count(), 0) // 记忆层清空（文件已删）
        XCTAssertEqual(store.count(), 0) // 事件层同清
        XCTAssertTrue(dayFileContents().isEmpty)
    }

    // ------------------------------------------------------------ (d) 同步挂钩：W8 同构事件体

    func testSyncExportW8IsomorphicEventBody() throws {
        let rec = MemoryRecord(
            tsMs: 1_793_730_973_174,
            device: "mac",
            appId: "com.apple.TextEdit",
            situation: Situation(
                beforeCursor: "今天开会", ocrDigest: "sha256:aa len:3",
                asrDigest: "sha256:bb len:4"),
            myReply: MyReply(text: "今天开会。", mode: .voice),
            meta: Meta(fromSuggestion: "prop-1", confidence: 0.0, sessionId: "s-1"),
            consent: .c1)
        let line = MemorySync.ingestJSONLLine(from: rec, deviceId: "mac-you")

        // W8 同构事件体 = hub /v1/ingest IngestIn = sdk ser::event_to_json 字段
        let ev = try JSONDecoder().decode(InteractionEvent.self, from: line.data(using: .utf8)!)
        XCTAssertEqual(ev.ts, 1_793_730_973_174)
        XCTAssertEqual(ev.deviceId, "mac-you")
        XCTAssertEqual(ev.appId, "com.apple.TextEdit")
        XCTAssertEqual(ev.kind, .voiceSession) // mode=voice → voice_session（hub EventKind 枚举）
        XCTAssertEqual(ev.textIn, "今天开会")
        XCTAssertEqual(ev.textOut, "今天开会。")
        XCTAssertEqual(ev.ocrDigest, "sha256:aa len:3")
        XCTAssertEqual(ev.asrDigest, "sha256:bb len:4")
        XCTAssertEqual(ev.suggestionTaken, 1) // from_suggestion 非空

        // kind 字面值与 hub EventKind 一致（契约即协议）
        XCTAssertTrue(EventKind.allCases.contains(ev.kind))

        // mode=text → key_session
        let t = MemorySync.ingestEvent(
            from: makeRecord(mode: .text), deviceId: "d")
        XCTAssertEqual(t.kind, .keySession)
        XCTAssertNil(t.suggestionTaken) // 无建议来源
    }

    func testSyncExportSkipsDeletedRecords() throws {
        let store = MemoryStore(rootDir: memDir)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.append(makeRecord(tsMs: now, reply: "留下", sessionId: "s-keep"))
        store.append(makeRecord(tsMs: now + 1, reply: "撤回", sessionId: "s-gone"))
        let target = store.query(limit: 10).first { $0.meta.sessionId == "s-gone" }!
        try store.delete(id: target.id)

        let text = store.exportIngestJSONL(deviceId: "mac-d")
        XCTAssertTrue(text.contains("留下"))
        XCTAssertFalse(text.contains("撤回")) // 撤回停传：物理移除后不再导出

        // JSONL 直进 ingest 队列
        let qpath = memDir + "/../ingest-queue.jsonl"
        let sink = JSONLQueueSink(path: qpath)
        let n = try sink.enqueueAll(store.allRecords(), deviceId: "mac-d")
        XCTAssertEqual(n, 1)
        let q = try String(contentsOfFile: qpath, encoding: .utf8)
        XCTAssertEqual(q.split(separator: "\n").count, 1)
        XCTAssertNotNil(
            try? JSONDecoder().decode(
                InteractionEvent.self, from: q.split(separator: "\n")[0].data(using: .utf8)!))
    }
}
