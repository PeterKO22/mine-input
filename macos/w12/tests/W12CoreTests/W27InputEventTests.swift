import XCTest

#if canImport(ContextCore)
import ContextCore
#endif
@testable import W12Core

/// W27 接线测试：W12C1Collector.onInputEvent()（按键/PTT 语音触发统一入口）——
/// 开 C1 打字→screen+OCR 入库+屏幕文本进 SuggestContext；关 C1/密码框/熔断零采集；
/// 同一输入会话内合并（防抖）；PTT 触发即时读屏。
final class W27InputEventTests: XCTestCase {
    var dbPath: String!
    var bridge: W12EventBridge!
    var screen: ScreenTextContext!
    var collector: W12C1Collector!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "w27-test-\(UUID().uuidString).db"
        bridge = W12EventBridge(path: dbPath)
        screen = ScreenTextContext()
        // W32 起读屏子开关默认 OFF（「屏幕上下文默认 OFF」）——本套件测的就是读屏链路，
        // 夹具显式置开（等价 ⌥M「读取屏幕内容以增强候选（需授权）」开关打开）。
        collector = W12C1Collector(bridge: bridge, settings: W12Settings(c1Screen: true))
        collector.screenContext = screen
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// 同步驱动 onInputEvent（completion 信号量）。
    @discardableResult
    private func fire(
        _ trigger: W12InputTrigger, secureInput: Bool = false
    ) -> W12C1Collector.Outcome {
        let sem = DispatchSemaphore(value: 0)
        var out: W12C1Collector.Outcome = .skipped("none")
        collector.onInputEvent(trigger, appId: "com.apple.TextEdit", secureInput: secureInput) {
            out = $0
            sem.signal()
        }
        sem.wait()
        return out
    }

    private func rows() -> [InteractionEvent] {
        bridge.store.query(InteractionStore.Query(limit: 100))
    }

    // ------------------------------------------------------------ 开 C1 → 打字 → 读屏

    func testKeystrokeWithC1OnIngestsScreenOCRAndFillsSuggestContext() throws {
        let png = try Self.makeTestImage(text: "W27 KEYBOARD READ SCREEN MARKER")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

        let out = fire(.keystroke)
        guard case .ingested(let id, let digest) = out else {
            return XCTFail("开 C1 打字应入库：\(out)")
        }
        XCTAssertGreaterThan(id, 0)
        XCTAssertTrue(W12Digest.isSummaryOnly(digest))

        // 采集日志：screen+OCR 条目（kind=key_session + ocr_digest），原文零落库
        let rs = rows()
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs[0].kind, .keySession)
        XCTAssertNotNil(rs[0].ocrDigest)
        XCTAssertTrue(rs[0].textIn.isEmpty && rs[0].textOut.isEmpty)

        // 上下文存储 + SuggestContext 带屏幕文本（推荐链）
        XCTAssertEqual(screen.count, 1, "OCR 文本进屏幕上下文存储")
        let ctx = collector.makeSuggestContext(beforeCursor: "开会", appId: "com.apple.TextEdit")
        XCTAssertFalse(ctx.screenText.isEmpty)
        XCTAssertTrue(ctx.screenText.contains("W27"), "screenText 含屏幕 OCR 内容：\(ctx.screenText)")

        // noteKeystroke 旧入口仍转发 onInputEvent（兼容不回归）
        Thread.sleep(forTimeInterval: 2.1)  // 出防抖窗
        let out2 = fire(.keystroke)
        guard case .ingested = out2 else { return XCTFail("二次按键出窗应入库：\(out2)") }
        XCTAssertEqual(rows().count, 2)
    }

    // ------------------------------------------------------------ 同一输入会话内合并

    func testSameInputSessionMergedByDebounce() throws {
        let png = try Self.makeTestImage(text: "MERGE")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

        // 首键触发采集（异步 OCR）；同会话立即连打 5 键——与首键几乎同时，
        // 必落防抖窗内（确定性合并断言，不依赖 OCR 耗时）。
        let sem = DispatchSemaphore(value: 0)
        var first: W12C1Collector.Outcome = .skipped("none")
        collector.onInputEvent(.keystroke, appId: "com.apple.TextEdit", secureInput: false) {
            first = $0
            sem.signal()
        }
        var reasons: [String] = []
        for _ in 0..<5 {
            collector.onInputEvent(.keystroke, appId: "com.apple.TextEdit", secureInput: false) { o in
                if case .skipped(let r) = o { reasons.append(r) }
            }
        }
        sem.wait()
        guard case .ingested = first else { return XCTFail("首轮应入库：\(first)") }
        XCTAssertEqual(reasons.count, 5, "防抖窗内 5 键均 skipped")
        XCTAssertTrue(reasons.allSatisfy { $0.contains("debounced") },
                      reasons.joined(separator: " | "))
        XCTAssertEqual(rows().count, 1, "同一输入会话内合并：6 键 → 1 轮采集")
        XCTAssertEqual(screen.count, 1)
    }

    // ------------------------------------------------------------ 关 C1 → 零采集

    func testC1OffZeroCollection() throws {
        let png = try Self.makeTestImage(text: "OFF")
        collector.captureSourceOverride = .imageFile(png)
        // 默认关（未显式开启）
        let out = fire(.keystroke)
        guard case .refused(let reason) = out else {
            return XCTFail("C1 关应 refused：\(out)")
        }
        XCTAssertTrue(reason.contains("disabled"), reason)
        XCTAssertEqual(rows().count, 0, "关 C1 → 零采集")
        XCTAssertEqual(screen.count, 0, "关 C1 → 零入上下文存储")
        XCTAssertTrue(
            collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty,
            "关 C1 → SuggestContext.screenText 空")
    }

    // ------------------------------------------------------------ 密码框 → 零采集

    func testSecureInputZeroCollection() throws {
        let png = try Self.makeTestImage(text: "SECRET")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

        let out = fire(.keystroke, secureInput: true)
        guard case .refused(let reason) = out else {
            return XCTFail("密码框应 refused：\(out)")
        }
        XCTAssertTrue(reason.contains("secure"), reason)
        XCTAssertEqual(rows().count, 0, "密码框 → 零采集")
        XCTAssertEqual(screen.count, 0, "密码框 → 零入上下文存储")
        XCTAssertTrue(
            collector.makeSuggestContext(beforeCursor: "x", secureInput: true).screenText.isEmpty,
            "密码框 → SuggestContext.screenText 空（零带出）")
    }

    // ------------------------------------------------------------ 熔断 → 零采集

    func testBreakerZeroCollection() throws {
        let png = try Self.makeTestImage(text: "BREAKER")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        bridge.breaker.trip()

        let out = fire(.keystroke)
        guard case .refused(let reason) = out else {
            return XCTFail("熔断应 refused：\(out)")
        }
        XCTAssertTrue(reason.contains("circuit breaker"), reason)
        XCTAssertEqual(rows().count, 0, "熔断 → 零采集")
        XCTAssertEqual(screen.count, 0, "熔断 → 零入上下文存储")
        XCTAssertTrue(
            collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty,
            "熔断 → SuggestContext.screenText 空")
    }

    // ------------------------------------------------------------ PTT 语音触发 → 即时读屏

    func testPttStartTriggersScreenReadAndEndClosesWindow() throws {
        let png = try Self.makeTestImage(text: "PTT")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

        // 右⌘按住 / ⌃⌥M → onInputEvent(.pttStart)：开语音触发窗 + 即时读屏
        let out = fire(.pttStart)
        guard case .ingested = out else { return XCTFail("pttStart 应即时读屏入库：\(out)") }
        XCTAssertEqual(rows().count, 1)

        // .pttEnd 收口（不采集）
        let end = fire(.pttEnd)
        guard case .skipped = end else { return XCTFail("pttEnd 应 skipped：\(end)") }
        XCTAssertEqual(rows().count, 1, "pttEnd 不采集")

        // 窗口收口后（无按键、非 PTT）→ 不采
        Thread.sleep(forTimeInterval: 2.1)
        let idle = fire(.pttEnd)
        guard case .skipped = idle else { return XCTFail("\(idle)") }
        XCTAssertEqual(rows().count, 1)
    }

    // ------------------------------------------------------------ makeSuggestContext 门禁

    func testMakeSuggestContextGates() throws {
        screen.noteOCR("屏幕上写着 W27 GATE CHECK")
        // C1 关 → 空
        XCTAssertTrue(collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty)
        // C1 开 → 非空
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)
        XCTAssertEqual(
            collector.makeSuggestContext(beforeCursor: "x").screenText,
            "屏幕上写着 W27 GATE CHECK")
        // 熔断 → 空
        bridge.breaker.trip()
        XCTAssertTrue(collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty)
        bridge.breaker.reset()
        // 密码框 → 空
        XCTAssertTrue(collector.makeSuggestContext(beforeCursor: "x", secureInput: true).screenText.isEmpty)
        // 关 C1（disableC1 清环）→ 空
        W12Privacy.disableC1(store: bridge.store)
        XCTAssertTrue(collector.makeSuggestContext(beforeCursor: "x").screenText.isEmpty)
    }

    // ------------------------------------------------------------ PTT 绕防抖（W27-fix 实锤）

    func testPttStartImmediateCaptureWithinDebounceWindow() throws {
        // 注入伪时钟（零 sleep、零墙钟竞态）：pttStart 在防抖窗内仍即时读屏；
        // 同窗内 keystroke 仍被防抖合并——防抖只合并按键流，不吞显式 PTT 触发
        //（产品缺陷回归测试：修复前 pttStart 与 keystroke 同走防抖判定，窗内被吞）。
        var t: TimeInterval = 1_000
        collector.clock = { t }
        let png = try Self.makeTestImage(text: "PTT IMMEDIATE")
        collector.captureSourceOverride = .imageFile(png)
        W12Privacy.enableC1(store: bridge.store, explicitConfirm: true)

        // 首键 → 采集（t+0.0s）
        guard case .ingested = fire(.keystroke) else { return XCTFail("首键应入库") }
        XCTAssertEqual(rows().count, 1)

        // t+0.5s（防抖 2.0s 窗内）：按键 → debounced 合并；pttStart → 绕防抖即时读屏
        t += 0.5
        let key = fire(.keystroke)
        guard case .skipped(let r) = key else { return XCTFail("窗内按键应 debounced：\(key)") }
        XCTAssertTrue(r.contains("debounced"), r)
        XCTAssertEqual(rows().count, 1, "窗内按键零新增")

        let ptt = fire(.pttStart)
        guard case .ingested(let id, let digest) = ptt else {
            return XCTFail("pttStart 防抖窗内应即时读屏入库（绕防抖）：\(ptt)")
        }
        XCTAssertGreaterThan(id, 0)
        XCTAssertTrue(W12Digest.isSummaryOnly(digest))
        XCTAssertEqual(rows().count, 2, "pttStart 即时采集：+1（窗内不被防抖吞）")

        // pttEnd 收口不采集
        guard case .skipped = fire(.pttEnd) else { return XCTFail("pttEnd 应 skipped") }
        XCTAssertEqual(rows().count, 2, "pttEnd 零新增")
    }

    // ------------------------------------------------------------ 夹具

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
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "w27-img-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}
