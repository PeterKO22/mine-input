// W20ProposalEngineTests.swift — 提案契约 v2 单测（Swift 侧镜像桩，N7）
//
// 红线断言与 ai/tests/test_proposal_v2.cpp 同题：**「未 confirm 不得执行」**——
// propose/伪造 handle observe 都不得产生执行；confirm 是执行唯一入口且幂等。
// 引擎行为逐条对齐 ai/backends/null/null_proposal_agent.cc（C++ 桩）。
import XCTest
@testable import W20Core

final class W20ProposalEngineTests: XCTestCase {
    func testProposeStreamsDemoProposalWithoutExecuting() {
        let engine = W20NullProposalEngine()
        let items = engine.propose(secureInput: false)
        XCTAssertEqual(items.count, 1)
        let p = items[0]
        XCTAssertEqual(p.id, "prop-null-1")
        XCTAssertEqual(p.kind, .plan)
        XCTAssertFalse(p.title.isEmpty && p.detail.isEmpty)
        XCTAssertEqual(p.actions.count, 3)
        // 红线 ①：propose 之后没有任何执行（未 confirm 不得执行）。
        XCTAssertEqual(engine.executionCount, 0)
    }

    func testSecureInputNotAccepted() {
        let engine = W20NullProposalEngine()
        XCTAssertEqual(engine.propose(secureInput: true), [])  // 同 v1 kDisabled
        XCTAssertEqual(engine.executionCount, 0)
    }

    func testForgedHandleObserveRefused() {
        let engine = W20NullProposalEngine()
        let forged = W20ExecHandle(id: "exec-forged", proposalID: "prop-null-1",
                                   state: .queued)
        var updates = 0
        // 红线 ②：伪造 handle 不回调、不执行。
        XCTAssertFalse(engine.observe(forged) { _ in updates += 1 })
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(engine.executionCount, 0)
    }

    func testConfirmIsSoleExecutionEntry() {
        let engine = W20NullProposalEngine()
        // 红线 ③：confirm 是执行唯一入口。
        let h = engine.confirm(proposalID: "prop-null-1")
        XCTAssertEqual(h.state, .queued)
        XCTAssertEqual(h.progress, 0)
        XCTAssertEqual(engine.executionCount, 1)
    }

    func testObserveProgressFlow() {
        let engine = W20NullProposalEngine()
        let h = engine.confirm(proposalID: "prop-null-1")
        var snaps: [W20ExecHandle] = []
        XCTAssertTrue(engine.observe(h) { snaps.append($0) })
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(snaps[0].state, .running)
        XCTAssertEqual(snaps[0].progress, 0.5)
        XCTAssertEqual(snaps[1].state, .done)
        XCTAssertEqual(snaps[1].progress, 1.0)
        XCTAssertFalse(snaps[1].result.isEmpty)  // 执行到出结果
    }

    func testRepeatConfirmIdempotent() {
        let engine = W20NullProposalEngine()
        let a = engine.confirm(proposalID: "prop-null-1")
        let b = engine.confirm(proposalID: "prop-null-1")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(engine.executionCount, 1)  // 不产生第二次执行
    }

    func testUnknownProposalFailed() {
        let engine = W20NullProposalEngine()
        let h = engine.confirm(proposalID: "no-such-proposal")
        XCTAssertEqual(h.state, .failed)
        XCTAssertFalse(h.result.isEmpty)
        XCTAssertEqual(engine.executionCount, 0)  // 不执行
    }

    func testCPlusPlusStubParity() throws {
        // 与 C++ 桩同内容（ai/backends/null/null_proposal_agent.cc::demo_proposal）：
        // 提案卡 UI 在 Squirrel 内接 C++ 桩，独立侧接本镜像——两侧行为一致。
        let p = W20NullProposalEngine.demoProposal()
        XCTAssertEqual(p.id, "prop-null-1")
        XCTAssertEqual(p.kind, .plan)
        XCTAssertEqual(p.title, "Null 示例方案")
        XCTAssertEqual(p.actions.map(\.id), ["act-1", "act-2", "act-3"])
    }
}
