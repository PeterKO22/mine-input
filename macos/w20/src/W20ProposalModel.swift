// W20ProposalModel.swift — 「提案→确认→执行」契约的 Swift 侧形态（N7）
//
// 契约唯一事实源 = ai/spi/ai_assist_v2.h（docs/技术方案-v0.4.md §15.2）。
// 本文件是 UI 侧镜像：Proposal{title/detail/actions} / ExecutionHandle{state/progress/result} /
// propose（流式提案）→ confirm（**用户显式确认才执行**）→ observe（进度/结果回填）。
//
// 引擎实现（同一契约、换实现零改动）：
//   - W20NullProposalEngine：Null 提案桩的 Swift 镜像（行为逐条对齐
//     ai/backends/null/null_proposal_agent.cc：同一条示例提案、同一状态流转、
//     同一红线语义），供 SwiftPM 独立构建/单测/脚本化实测驱动；
//   - W20CppProposalEngine（macos/w20/src/W20SquirrelGlue.swift，仅编进 Squirrel.app）：
//     经 ObjC++ 桥（macos/w20/bridge/W20ProposalBridge）驱动 **C++ NullProposalAgent**
//     ——提案卡 UI 在真实 app 内接的就是 (b) 的 C++ 桩。
//
// 红线（契约头 §15.2）：confirm 只允许由用户显式动作（提案卡「确认执行」按钮）调用；
// 自动执行不存在；未经 confirm 的执行 id 不得执行。
import Foundation

// MARK: - 契约类型（对齐 ai/spi/ai_assist_v2.h）

public enum W20ProposalKind: String {
    case reply, task, plan
}

public struct W20ProposalAction: Equatable {
    public var id: String
    public var title: String
    public var detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct W20ProposalItem: Equatable {
    public var id: String
    public var kind: W20ProposalKind
    public var title: String
    public var detail: String
    public var actions: [W20ProposalAction]

    public init(id: String, kind: W20ProposalKind, title: String, detail: String,
                actions: [W20ProposalAction]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actions = actions
    }
}

public enum W20ExecState: String {
    case queued, running, done, failed
}

public struct W20ExecHandle: Equatable {
    public var id: String
    public var proposalID: String
    public var state: W20ExecState
    public var progress: Double  // 0..1
    public var result: String    // done=结果 / failed=简要原因 / 其余为空

    public init(id: String, proposalID: String, state: W20ExecState,
                progress: Double = 0, result: String = "") {
        self.id = id
        self.proposalID = proposalID
        self.state = state
        self.progress = progress
        self.result = result
    }
}

// MARK: - 引擎协议（propose → confirm → observe）

public protocol W20ProposalEngine: AnyObject {
    /// 流式提案（UI 侧同步展平）：secure_input 直接未受理（[]，同 v1 kDisabled）。
    /// 红线：只提案，绝不执行。
    func propose(secureInput: Bool) -> [W20ProposalItem]

    /// **仅由提案卡「确认执行」按钮调用**（用户显式动作；自动执行不存在）。
    /// 未知 id → state=.failed；重复 confirm 幂等（同一执行 id，不二次执行）。
    func confirm(proposalID: String) -> W20ExecHandle

    /// 进度/结果回填：state 流转 queued→running→done。
    /// handle 未经 confirm（未知执行 id）→ false，不回调、不执行。
    func observe(_ handle: W20ExecHandle,
                 onUpdate: @escaping (W20ExecHandle) -> Void) -> Bool
}

// MARK: - Null 提案桩（Swift 镜像，逐条对齐 ai/backends/null/null_proposal_agent.cc）

public final class W20NullProposalEngine: W20ProposalEngine {
    public static let demoProposalID = "prop-null-1"

    private var executions: [String: W20ExecHandle] = [:]   // exec_id → handle
    private var confirmed: [String: String] = [:]           // proposal_id → exec_id
    private var nextExec = 1

    public init() {}

    /// 已 confirm（= 已执行）次数：红线断言「未 confirm 不得执行」。
    public var executionCount: Int { executions.count }

    /// 固定示例提案（与 C++ NullProposalAgent::demo_proposal 同内容）。
    public static func demoProposal() -> W20ProposalItem {
        W20ProposalItem(
            id: demoProposalID, kind: .plan,
            title: "Null 示例方案",
            detail: "空后端演示提案：确认后按动作清单逐步执行（Null 桩不产生任何真实副作用）。"
                + "真实执行器（agent runner）随 Hub 迭代落地（§15.2）。",
            actions: [
                W20ProposalAction(id: "act-1", title: "汇总上下文",
                                  detail: "收集当前输入情境（C0 最小上下文）"),
                W20ProposalAction(id: "act-2", title: "生成草稿",
                                  detail: "按方案 detail 产出结果草稿"),
                W20ProposalAction(id: "act-3", title: "回填结果",
                                  detail: "把执行结果回填提案卡（observe）"),
            ])
    }

    public func propose(secureInput: Bool) -> [W20ProposalItem] {
        if secureInput { return [] }  // 未受理：同 v1 kDisabled
        return [Self.demoProposal()]
    }

    public func confirm(proposalID: String) -> W20ExecHandle {
        if let execID = confirmed[proposalID], let h = executions[execID] {
            return h  // 幂等：同一执行，不再跑
        }
        guard proposalID == Self.demoProposalID else {
            return W20ExecHandle(id: "", proposalID: proposalID, state: .failed,
                                 result: "error: unknown proposal id")
        }
        let h = W20ExecHandle(id: "exec-null-\(nextExec)", proposalID: proposalID,
                              state: .queued)  // confirm 只入队
        nextExec += 1
        confirmed[proposalID] = h.id
        executions[h.id] = h
        return h
    }

    public func observe(_ handle: W20ExecHandle,
                        onUpdate: @escaping (W20ExecHandle) -> Void) -> Bool {
        // 红线：未经 confirm 的 handle（伪造/未知执行 id）拒绝——不回调、不执行。
        guard let base = executions[handle.id] else { return false }
        var running = base
        running.state = .running
        running.progress = 0.5
        onUpdate(running)
        var done = base
        done.state = .done
        done.progress = 1.0
        done.result = "null 执行完成：Null 示例方案（3 个动作）"
        onUpdate(done)
        return true
    }
}
