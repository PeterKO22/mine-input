import XCTest

#if canImport(ContextCore)
import ContextCore
#endif
@testable import W12Core

/// W29 回复留存（L3）单测：开关持久化（meta，跨进程）/ 留存开关与生产桥闸 /
/// 密码框拒收恒不变。伪时钟口径：事件 ts 全部显式注入（固定毫秒值），零 Thread.sleep。
final class W29RetentionTests: XCTestCase {
    var dbPath: String!
    var bridge: W12EventBridge!

    /// 固定时间轴（伪时钟）：毫秒级注入，与墙钟无关。
    let t0: Int64 = 1_793_730_973_000

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "w29-retention-\(UUID().uuidString).db"
        bridge = W12EventBridge(path: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // ------------------------------------------------------------ (1) 开关持久化

    func testRetentionSwitchPersistsInMetaAcrossInstances() throws {
        // 默认关（新库 meta 无值）
        XCTAssertFalse(W12Privacy.isCommitTextRetentionEnabled(store: bridge.store))
        XCTAssertFalse(bridge.isCommitTextRetentionEnabled)

        // 不显式确认 → 拒绝开启，meta 不变
        XCTAssertFalse(
            W12Privacy.enableCommitTextRetention(store: bridge.store, explicitConfirm: false))
        XCTAssertFalse(W12Privacy.isCommitTextRetentionEnabled(store: bridge.store))

        // 显式确认 → 开（meta commit_text_retention=1）
        XCTAssertTrue(
            W12Privacy.enableCommitTextRetention(store: bridge.store, explicitConfirm: true))
        XCTAssertEqual(bridge.store.metaGet("commit_text_retention"), "1")

        // 跨进程等价：另一 store 实例（同路径）读到同一持久值
        let other = try InteractionStore(path: dbPath)
        XCTAssertTrue(W12Privacy.isCommitTextRetentionEnabled(store: other))

        // 关闭 → meta=0，跨实例同读
        W12Privacy.disableCommitTextRetention(store: bridge.store)
        XCTAssertEqual(bridge.store.metaGet("commit_text_retention"), "0")
        XCTAssertFalse(W12Privacy.isCommitTextRetentionEnabled(store: other))
    }

    // ------------------------------------------------------------ (2) 留存开关 → text_out

    func testBridgeRetainsTextOutPerPersistedSwitch() {
        // 关（默认）→ text_out 落库为空
        let r1 = bridge.reportKeySession(
            textIn: "ni hao", textOut: "你好", appId: "com.apple.TextEdit", ts: t0)
        XCTAssertEqual(r1.storedId != nil, true)
        XCTAssertEqual(rows().first?.textOut, "", "留存关 → text_out 空")

        // 开（持久开关）→ text_out 留存
        W12Privacy.enableCommitTextRetention(store: bridge.store, explicitConfirm: true)
        bridge.reportKeySession(
            textIn: "明天的会改到10点", textOut: "收到，我会准时到",
            appId: "com.apple.TextEdit", ts: t0 + 60_000)
        bridge.reportVoiceSession(
            textIn: "", textOut: "今天开会。", appId: "com.apple.TextEdit", ts: t0 + 120_000)
        bridge.reportCandidatePick(
            textIn: "zni", textOut: "智能", appId: "com.apple.TextEdit", ts: t0 + 180_000)
        let kept = rows()
        XCTAssertEqual(kept.count, 4)
        XCTAssertEqual(kept.first?.textOut, "智能", "最后一个事件 text_out 已留存")
        XCTAssertTrue(kept.contains { $0.textOut == "收到，我会准时到" })
        XCTAssertTrue(kept.contains { $0.textOut == "今天开会。" })

        // 关（持久开关）→ 新事件 text_out 空（旧留存不回改）
        W12Privacy.disableCommitTextRetention(store: bridge.store)
        bridge.reportKeySession(
            textIn: "晚上一起吃饭", textOut: "好的晚上见",
            appId: "com.apple.TextEdit", ts: t0 + 240_000)
        XCTAssertEqual(rows().first?.textOut, "", "关留存 → 新事件 text_out 空")
        XCTAssertTrue(
            rows().contains { $0.textOut == "收到，我会准时到" }, "既有留存不回改（可查可删）")
    }

    func testCommitRetentionOverrideForProbes() {
        // 探针/测试直通：override 强制留存（生产恒 nil 走持久开关）
        bridge.commitRetentionOverride = true
        bridge.reportKeySession(
            textIn: "x", textOut: "y", appId: "com.apple.TextEdit", ts: t0)
        XCTAssertEqual(rows().first?.textOut, "y")

        bridge.commitRetentionOverride = false
        bridge.reportKeySession(
            textIn: "x2", textOut: "y2", appId: "com.apple.TextEdit", ts: t0 + 1_000)
        XCTAssertEqual(rows().first?.textOut, "", "override=false 强制清空")
    }

    // ------------------------------------------------------------ (3) 密码框拒收（恒不变）

    func testSecureInputRefusedEvenWithRetentionOn() {
        W12Privacy.enableCommitTextRetention(store: bridge.store, explicitConfirm: true)
        XCTAssertTrue(bridge.isCommitTextRetentionEnabled)

        // 密码框/安全输入：恒拒收（不入库，text_out 无从谈起）
        let r = bridge.reportKeySession(
            textIn: "password", textOut: "hunter2",
            appId: "com.apple.TextEdit", secureInput: true, ts: t0)
        XCTAssertTrue(r.isRefused)
        XCTAssertEqual(bridge.store.count(), 0, "密码框零入库")
        if case .refused(let err) = r {
            XCTAssertTrue("\(err)".contains("secure"), "\(err)")
        } else {
            XCTFail("secureInput 应 refused")
        }

        // 语音/候选同理
        XCTAssertTrue(
            bridge.reportVoiceSession(
                textIn: "", textOut: "s", appId: "com.apple.TextEdit",
                secureInput: true, ts: t0 + 1_000).isRefused)
        XCTAssertTrue(
            bridge.reportCandidatePick(
                textIn: "s", textOut: "s", appId: "com.apple.TextEdit",
                secureInput: true, ts: t0 + 2_000).isRefused)
        XCTAssertEqual(bridge.store.count(), 0)
    }

    // ------------------------------------------------------------ 工具

    private func rows() -> [InteractionEvent] {
        bridge.store.query(InteractionStore.Query(limit: 100))
    }
}
