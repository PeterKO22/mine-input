import XCTest

#if canImport(ContextCore)
import ContextCore
#endif
@testable import W12Core

/// W12 核心语义测试：摘要/长度不落原文、防抖与仅输入时触发、隐私门禁
///（C1 显式开关/密码框自动停/黑名单/熔断立即停）、OCR→摘要入库、
/// 提词浮层流式刷新→采纳入库、W7×W9 三事件上报。
final class W12CoreTests: XCTestCase {
    var dbPath: String!
    var bridge: W12EventBridge!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "w12-test-\(UUID().uuidString).db"
        bridge = W12EventBridge(path: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // ------------------------------------------------------------ 摘要

    func testDigestIsSummaryOnlyNoContent() {
        let text = "会议纪要 W12 上下文采集测试"
        let d = W12Digest.summary(text, lines: 2)
        XCTAssertTrue(d.hasPrefix("sha256:"), d)
        XCTAssertTrue(d.contains("len:\(text.count)"), d)
        XCTAssertTrue(d.contains("lines:2"), d)
        XCTAssertFalse(d.contains("会议"), "摘要串绝不含原文")
        XCTAssertTrue(W12Digest.isSummaryOnly(d))
        // 内容变 → 摘要变；长度同、内容不同 → 摘要不同
        XCTAssertNotEqual(d, W12Digest.summary("会议纪要 W12 上下文采集测X", lines: 2))
    }

    // ------------------------------------------------------------ 防抖 + 仅输入时触发

    func testTriggerDebounceAndInputWindow() {
        // 无输入活动（非 PTT、无按键）→ 不采
        var d = W12C1Collector.decideTrigger(
            now: 100, lastCaptureAt: nil, lastKeyAt: nil, pttActive: false)
        XCTAssertFalse(d.shouldCapture, d.reason)

        // 按键触发窗内 → 采
        d = W12C1Collector.decideTrigger(
            now: 100, lastCaptureAt: nil, lastKeyAt: 99.5, pttActive: false)
        XCTAssertTrue(d.shouldCapture, d.reason)

        // 防抖 2s：1s 后再按键 → 不采
        d = W12C1Collector.decideTrigger(
            now: 101, lastCaptureAt: 100, lastKeyAt: 101, pttActive: false)
        XCTAssertFalse(d.shouldCapture, d.reason)

        // 2s 后 → 采
        d = W12C1Collector.decideTrigger(
            now: 102, lastCaptureAt: 100, lastKeyAt: 102, pttActive: false)
        XCTAssertTrue(d.shouldCapture, d.reason)

        // PTT 期间 → 采（语音窗，仅输入时）
        d = W12C1Collector.decideTrigger(
            now: 200, lastCaptureAt: nil, lastKeyAt: nil, pttActive: true)
        XCTAssertTrue(d.shouldCapture, d.reason)
    }

    // ------------------------------------------------------------ 隐私门禁

    func testC1DefaultOffRequiresExplicitEnable() {
        let c1 = W12C1Collector(bridge: bridge, settings: W12Settings())
        XCTAssertFalse(c1.isC1Enabled, "C1 默认关")
        let out = c1.captureAndIngestSync(
            source: .imageFile(URL(fileURLWithPath: "/nonexistent.png")),
            appId: "com.apple.TextEdit", secureInput: false)
        guard case .refused(let reason) = out else {
            return XCTFail("默认关时应拒绝：\(out)")
        }
        XCTAssertTrue(reason.contains("disabled"), reason)
        // 显式开启（explicitConfirm: true）后才允许
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        XCTAssertTrue(c1.isC1Enabled)
        W12Privacy.disableC1(store: bridge.store)
        XCTAssertFalse(c1.isC1Enabled)
        // 不显式确认 → 拒绝开启
        XCTAssertFalse(W12Privacy.enableC1(store: bridge.store, explicitConfirm: false))
    }

    func testSecureInputAutoPauseBlacklistAndBreaker() {
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        let c1 = W12C1Collector(bridge: bridge, settings: W12Settings())

        // 密码框（secure input）→ 自动停不可关
        guard case .refused(let r1) = c1.precheck(appId: "com.apple.TextEdit", secureInput: true) else {
            return XCTFail("secure input 应拒收")
        }
        XCTAssertTrue(r1.contains("secure input"), r1)

        // 敏感应用黑名单 → 跳过
        guard case .skipped(let r2) = c1.precheck(
            appId: "com.apple.keychainaccess", secureInput: false) else {
            return XCTFail("黑名单应跳过")
        }
        XCTAssertTrue(r2.contains("blacklisted"), r2)

        // 熔断 → 立即停
        bridge.breaker.trip()
        guard case .refused(let r3) = c1.precheck(appId: "com.apple.TextEdit", secureInput: false) else {
            return XCTFail("熔断应拒收")
        }
        XCTAssertTrue(r3.contains("circuit breaker"), r3)
        let out = c1.captureAndIngestSync(
            source: .imageFile(URL(fileURLWithPath: "/nonexistent.png")),
            appId: "com.apple.TextEdit", secureInput: false)
        guard case .refused(let r4) = out else {
            return XCTFail("熔断后采集应拒收：\(out)")
        }
        XCTAssertTrue(r4.contains("circuit breaker"), r4)
    }

    // ------------------------------------------------------------ OCR 摘要入库（sqlite3 可查）

    func testOCRDigestIngestStoresDigestOnly() throws {
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        let c1 = W12C1Collector(bridge: bridge, settings: W12Settings())
        let png = try Self.makeTestImage(text: "W12 摘要入库测试 ALPHA")
        let out = c1.captureAndIngestSync(
            source: .imageFile(png), appId: "com.apple.TextEdit", secureInput: false)
        guard case .ingested(let id, let digest) = out else {
            return XCTFail("OCR 摘要应入库：\(out)")
        }
        XCTAssertGreaterThan(id, 0)
        XCTAssertTrue(W12Digest.isSummaryOnly(digest), digest)

        let rows = bridge.store.query(InteractionStore.Query(limit: 10))
        XCTAssertEqual(rows.count, 1)
        let ev = rows[0]
        XCTAssertEqual(ev.kind, .keySession)
        XCTAssertNotNil(ev.ocrDigest)
        XCTAssertEqual(ev.asrDigest, nil)
        // 隐私红线：原文/全文不落库（text_in/text_out 空，digest 只含摘要/长度）
        XCTAssertTrue(ev.textIn.isEmpty)
        XCTAssertTrue(ev.textOut.isEmpty)
        XCTAssertFalse(ev.ocrDigest!.contains("ALPHA"), "digest 列绝不含 OCR 全文")
    }

    // ------------------------------------------------------------ W7×W9 接线

    func testW7EventsReportToInteractionStore() {
        bridge.reportKeySession(textIn: "ni hao", textOut: "你好", appId: "com.apple.TextEdit")
        bridge.reportVoiceSession(textIn: "", textOut: "今天开会。", appId: "com.apple.TextEdit")
        bridge.reportCandidatePick(textIn: "zni", textOut: "智能", appId: "com.apple.TextEdit")
        XCTAssertEqual(bridge.store.count(), 3)
        XCTAssertEqual(bridge.store.count(kind: .keySession), 1)
        XCTAssertEqual(bridge.store.count(kind: .voiceSession), 1)
        XCTAssertEqual(bridge.store.count(kind: .candidatePick), 1)
    }

    func testPttTranscriptAttachesAsrDigestWhenC1On() {
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        let c1 = W12C1Collector(bridge: bridge, settings: W12Settings())
        let out = c1.notePttTranscript(
            "今天天气不错。", appId: "com.apple.TextEdit", secureInput: false)
        guard case .ingested = out else { return XCTFail("\(out)") }
        let rows = bridge.store.query(InteractionStore.Query(limit: 10))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .voiceSession)
        XCTAssertNotNil(rows[0].asrDigest)
        XCTAssertTrue(W12Digest.isSummaryOnly(rows[0].asrDigest!))
        XCTAssertFalse(rows[0].asrDigest!.contains("天气"), "asr_digest 绝不含转写全文")

        // C1 关（默认）：事件仍上报（W7×W9 接线），但不带摘要
        W12Privacy.disableC1(store: bridge.store)
        c1.notePttTranscript("另一段话。", appId: "com.apple.TextEdit", secureInput: false)
        let rows2 = bridge.store.query(InteractionStore.Query(limit: 10))
        XCTAssertEqual(rows2.count, 2)
        XCTAssertEqual(rows2.filter { $0.asrDigest != nil }.count, 1, "仅 C1 开启期间的会话带摘要")
        XCTAssertEqual(rows2.filter { $0.asrDigest == nil }.count, 1, "C1 关后的会话不带摘要")
        XCTAssertTrue(rows2.compactMap { $0.asrDigest }.first!.contains("len:7"))
    }

    // ------------------------------------------------------------ 提词浮层：流式刷新 → Tab 采纳

    func testPrompterStreamingRefreshAndAdopt() async {
        let model = W12PrompterModel()
        let ctx = SuggestContext(beforeCursor: "今天开会", appId: "com.apple.TextEdit")
        await model.run(ctx: ctx, backend: NullSuggestBackend(), timeout: 0.8)

        // 流式刷新：3×Δ + 恰好一次终止（kDone）
        XCTAssertEqual(model.candidates.count, 3)
        XCTAssertEqual(model.frames.count, 4)
        XCTAssertEqual(model.frames.last?.status, .kDone)
        XCTAssertTrue(model.refreshLog[0].hasPrefix("Δ +"), model.refreshLog[0])
        XCTAssertTrue(model.refreshLog.last!.contains("done"))
        XCTAssertFalse(model.terminated == false, "终止后更新丢弃")

        // Tab 采纳 → suggestion_feedback 入库（taken=1）
        let chosen = model.adopt(index: 0, textIn: "今天开会", appId: "com.apple.TextEdit", bridge: bridge)
        XCTAssertNotNil(chosen)
        let rows = bridge.store.query(
            InteractionStore.Query(limit: 10, kind: .suggestionFeedback))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].suggestionTaken, 1)
        XCTAssertEqual(rows[0].suggestionShown, 3)
    }

    // ------------------------------------------------------------ 便利包装（同步驱动 async 采集）

    private func sync(_ body: @escaping () async -> W12C1Collector.Outcome) -> W12C1Collector.Outcome {
        let sem = DispatchSemaphore(value: 0)
        var result: W12C1Collector.Outcome = .skipped("no result")
        Task { result = await body(); sem.signal() }
        sem.wait()
        return result
    }

    static func makeTestImage(text: String) throws -> URL {
        let img = NSImage(size: NSSize(width: 600, height: 160))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
        (text as NSString).draw(at: NSPoint(x: 16, y: 60), withAttributes: attrs)
        img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "w12-img-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}

extension W12C1Collector {
    /// 测试便利：同步驱动 async captureAndIngest。
    func captureAndIngestSync(
        source: W12CaptureSource, appId: String?, secureInput: Bool
    ) -> Outcome {
        let sem = DispatchSemaphore(value: 0)
        var result: Outcome = .skipped("no result")
        Task {
            result = await self.captureAndIngest(
                source: source, kind: .keySession,
                appId: appId, secureInput: secureInput)
            sem.signal()
        }
        sem.wait()
        return result
    }
}
