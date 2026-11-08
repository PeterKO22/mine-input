import ContextCore
import Foundation
import XCTest

@testable import MemoryCore

/// W29 回复留存（L3）配对计数测试：「段内无留存回复」与「真取消」分开计数
/// （误导修复——「N cancelled」不再冒充真取消）+ 提示语。
/// 伪时钟口径：事件 ts 全部显式注入（固定毫秒值），零 Thread.sleep。
final class W29PairingRetentionTests: XCTestCase {

    /// 固定基点（2026-11-03 前后，仅作确定性时间轴；与真实时钟无关）。
    let base: Int64 = 1_793_730_973_000

    func makeEvent(
        ts: Int64, appId: String = "com.apple.TextEdit",
        kind: EventKind = .keySession, textIn: String, textOut: String
    ) -> InteractionEvent {
        InteractionEvent(
            ts: ts, deviceId: "mac-d", appId: appId, kind: kind,
            textIn: textIn, textOut: textOut)
    }

    // ------------------------------------------------------------ 分开计数

    func testNoRetainedReplySplitFromTrueCancel() {
        // 会话 1（ts 固定）：text_out 全空（留存未开时的上屏/取消不可分辨）
        // 会话 2（+60s > 30s gap → 新段）：text_out 非空 → 正常配对。
        let events = [
            makeEvent(ts: base, textIn: "ni hao", textOut: ""),
            makeEvent(ts: base + 60_000, textIn: "晚上一起吃饭", textOut: "好的晚上见"),
        ]

        // 留存开关关（W29 语义）：全空段归「段内无留存回复」，不冒充真取消
        var off = MemoryPairing.Options()
        off.retentionEnabled = false
        let outOff = MemoryPairing.pair(events: events, options: off)
        XCTAssertEqual(outOff.sessionCount, 2)
        XCTAssertEqual(outOff.noRetainedReplyCount, 1, "留存未开 → 段内无留存回复")
        XCTAssertEqual(outOff.cancelledCount, 0, "留存未开时不冒充真取消")
        XCTAssertEqual(outOff.memories.count, 1)

        // 留存开关开（默认，W19 既有语义）：全空段 = 真取消
        let outOn = MemoryPairing.pair(events: events)  // Options() 默认 retentionEnabled=true
        XCTAssertEqual(outOn.sessionCount, 2)
        XCTAssertEqual(outOn.cancelledCount, 1, "留存开着 → text_out 全空 = 真取消")
        XCTAssertEqual(outOn.noRetainedReplyCount, 0)

        // 配对产物本身不受计数归类影响：situation + my_reply 齐全
        let m = outOff.memories[0]
        XCTAssertEqual(m.situation.beforeCursor, "晚上一起吃饭")
        XCTAssertEqual(m.myReply.text, "好的晚上见")
    }

    func testCountsAddUpAcrossMixedSessions() {
        // 4 段（同 app，相邻 60s > 30s gap）：2 段有回复、2 段 text_out 全空。
        let events = [
            makeEvent(ts: base, textIn: "s1", textOut: ""),
            makeEvent(ts: base + 60_000, textIn: "s2", textOut: "r2"),
            makeEvent(ts: base + 120_000, textIn: "s3", textOut: ""),
            makeEvent(ts: base + 180_000, textIn: "s4", textOut: "r4"),
        ]
        var off = MemoryPairing.Options()
        off.retentionEnabled = false
        let out = MemoryPairing.pair(events: events, options: off)
        XCTAssertEqual(out.sessionCount, 4)
        XCTAssertEqual(out.memories.count, 2)
        XCTAssertEqual(out.noRetainedReplyCount, 2)
        XCTAssertEqual(out.cancelledCount, 0)
        XCTAssertEqual(
            out.memories.count + out.noRetainedReplyCount + out.cancelledCount,
            out.sessionCount, "三类计数之和 = 会话总数")
    }

    // ------------------------------------------------------------ 提示语

    func testRetentionHintWording() {
        // 验收原文要求的提示语必须逐字在场（memoryctl pair 输出引用同一常量）。
        XCTAssertTrue(
            MemoryPairing.noRetainedReplyHint.contains("回复留存未开，开后新会话才会配对"),
            MemoryPairing.noRetainedReplyHint)
    }
}
