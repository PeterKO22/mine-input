import XCTest
@testable import ContextCore

final class ContextCoreTests: XCTestCase {
    var dbPath: String!
    var store: InteractionStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory()
            + "w9-test-\(UUID().uuidString)/interaction.db"
        store = try InteractionStore(path: dbPath)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent)
    }

    // ------------------------------------------------------------ store

    func testInsertQueryRoundtrip() throws {
        let ev = InteractionEvent(
            ts: 1_700_000_000_000, deviceId: "test-dev",
            appId: "com.apple.TextEdit", kind: .keySession,
            textIn: "ni hao", textOut: "你好",
            keystrokeCadence: 3.2, suggestionShown: 2, suggestionTaken: 1)
        let res = store.insert(ev)
        XCTAssertEqual(res.storedId, 1)
        XCTAssertEqual(store.count(), 1)

        let rows = store.query()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].deviceId, "test-dev")
        XCTAssertEqual(rows[0].kind, .keySession)
        XCTAssertEqual(rows[0].textIn, "ni hao")
        XCTAssertEqual(rows[0].keystrokeCadence, 3.2)
        XCTAssertEqual(rows[0].suggestionShown, 2)
        XCTAssertEqual(rows[0].suggestionTaken, 1)
    }

    func testKindFilterAndCount() throws {
        store.insert(InteractionEvent(deviceId: "d", kind: .keySession))
        store.insert(InteractionEvent(deviceId: "d", kind: .voiceSession))
        store.insert(InteractionEvent(deviceId: "d", kind: .suggestionFeedback))
        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.count(kind: .voiceSession), 1)
        XCTAssertEqual(store.query(.init()).count, 3)
        var q = InteractionStore.Query()
        q.kind = .suggestionFeedback
        XCTAssertEqual(store.query(q).count, 1)
    }

    func testExportClearAndPrune() throws {
        store.insert(InteractionEvent(
            ts: 1_000, deviceId: "d", kind: .keySession,
            textIn: "hello,world"))
        store.insert(InteractionEvent(
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            deviceId: "d", kind: .keySession))

        let jsonl = store.exportJSONL()
        XCTAssertTrue(jsonl.contains("\"device_id\":\"d\""))
        XCTAssertTrue(jsonl.contains("\"kind\":\"key_session\""))
        XCTAssertTrue(jsonl.contains("hello,world"))

        let csv = store.exportCSV()
        XCTAssertTrue(csv.hasPrefix("ts,device_id,app_id,kind,text_in"))
        XCTAssertTrue(csv.contains("hello,world"))

        // 30 天滚动：ts=1000（1970）应被裁掉
        XCTAssertEqual(store.prune(olderThanDays: 30), 1)
        XCTAssertEqual(store.count(), 1)

        XCTAssertEqual(store.clearAll(), 1)
        XCTAssertEqual(store.count(), 0)
    }

    // ------------------------------------------------------------ breaker

    func testBreakerStopsIngestButKeepsLog() throws {
        store.insert(InteractionEvent(deviceId: "d", kind: .keySession))
        let breaker = CircuitBreaker(store: store)
        XCTAssertFalse(breaker.isTripped)

        breaker.trip()
        XCTAssertTrue(breaker.isTripped)
        let res = store.insert(InteractionEvent(deviceId: "d", kind: .keySession))
        XCTAssertTrue(res.isRefused)
        // 日志保留、不新增
        XCTAssertEqual(store.count(), 1)

        // 跨进程语义：新 store 实例读同一 meta 仍为 tripped
        let store2 = try InteractionStore(path: dbPath)
        XCTAssertTrue(store2.isBreakerTripped)
        XCTAssertTrue(store2.insert(InteractionEvent(deviceId: "d", kind: .keySession)).isRefused)

        breaker.reset()
        XCTAssertFalse(breaker.isTripped)
        XCTAssertTrue(store.insert(InteractionEvent(deviceId: "d", kind: .keySession)).isRefused == false)
    }

    func testSecureInputAutoPause() throws {
        let res = store.insert(
            InteractionEvent(deviceId: "d", kind: .keySession),
            secureInput: true)
        XCTAssertTrue(res.isRefused)
        XCTAssertEqual(store.count(), 0)
    }

    // ------------------------------------------------------------ collector（C0 红线）

    func testClipboardDefaultOff() throws {
        let breaker = CircuitBreaker(store: store)
        let collector = C0Collector(store: store, breaker: breaker)
        XCTAssertFalse(collector.clipboardCollectionEnabled)
        // 未显式开启时取样被拒
        XCTAssertTrue(collector.recordClipboardSample().isRefused)
        // 显式确认才可开
        XCTAssertFalse(collector.enableClipboardCollection(explicitConfirm: false))
        XCTAssertTrue(collector.enableClipboardCollection(explicitConfirm: true))
        XCTAssertTrue(collector.clipboardCollectionEnabled)
    }

    func testCommitTextRetentionDefaultOff() throws {
        let breaker = CircuitBreaker(store: store)
        let collector = C0Collector(store: store, breaker: breaker)
        collector.recordKeySession(textIn: "ni hao", textOut: "你好")
        let rows = store.query()
        XCTAssertEqual(rows[0].textIn, "ni hao") // 输入历史（C0）保留
        XCTAssertEqual(rows[0].textOut, "")     // 上屏文本留存默认关
    }

    func testBlacklistRefused() throws {
        let breaker = CircuitBreaker(store: store)
        let collector = C0Collector(store: store, breaker: breaker)
        let res = collector.recordKeySession(
            textIn: "x", appId: "com.apple.keychainaccess")
        XCTAssertTrue(res.isRefused)
        XCTAssertEqual(store.count(), 0)
    }

    func testSecureInputRefusedAtCollector() throws {
        let breaker = CircuitBreaker(store: store)
        let collector = C0Collector(store: store, breaker: breaker)
        let res = collector.recordKeySession(textIn: "pwd", secureInput: true)
        XCTAssertTrue(res.isRefused)
        XCTAssertEqual(store.count(), 0)
    }

    // ------------------------------------------------------------ suggest（Null 后端流式语义）

    func testNullBackendStreamSemantics() async {
        let backend = NullSuggestBackend()
        let ctx = SuggestContext(beforeCursor: "今天开会")
        var statuses: [StreamStatus] = []
        var candidates: [Candidate] = []
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task {
                await backend.suggest(ctx: ctx, timeout: 0.8) { upd in
                    statuses.append(upd.status)
                    candidates.append(contentsOf: upd.candidates)
                }
                cont.resume()
            }
        }
        // 先若干 kDelta，后恰好一次终止（kDone）
        XCTAssertEqual(statuses.last, .kDone)
        XCTAssertEqual(statuses.filter { $0 == .kDone }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == .kDelta }.count, candidates.count)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].source, "null")
        XCTAssertTrue(candidates[0].text.contains("今天开会"))
    }

    func testEventKindMatchesHubEnum() {
        // 契约即协议：与 hub/app/main.py EventKind 字面值一致
        XCTAssertEqual(EventKind.keySession.rawValue, "key_session")
        XCTAssertEqual(EventKind.voiceSession.rawValue, "voice_session")
        XCTAssertEqual(EventKind.candidatePick.rawValue, "candidate_pick")
        XCTAssertEqual(EventKind.suggestionFeedback.rawValue, "suggestion_feedback")
    }
}
