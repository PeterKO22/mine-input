// W20SquirrelGlue.swift —— W20 在 Squirrel/IMK 侧的接线（仅编进 Squirrel，
// SwiftPM 独立构建以 W20_STANDALONE 排除——SquirrelInputController 只存在于 app 目标）。
//
// 职责（任务书 c/d）：
//   (c) 记忆管理界面入口：⌥M 热键（handle() 拦截）/ 菜单项「记忆管理…」→ W20MemoryPanel
//       浮层（顶部常显采集状态 + 一键熔断；时间线/搜索/编辑/删除/导出）；
//   (d) 提案卡接 **C++ Null 提案桩**：W20CppProposalEngine 经 ObjC++ 桥
//       （macos/w20/bridge/W20ProposalBridge）驱动 ai/backends/null/null_proposal_agent.cc
//       ——UI 的 propose/confirm/observe 与 ai/ 单测断言的是同一个桩。
//
// 红线（§15.2）：confirm 只在提案卡「确认执行」按钮的 action 里发生；本胶水不提供
// 任何自动 confirm 路径。
#if !W20_STANDALONE
import AppKit
import Foundation

#if canImport(ContextCore)
import ContextCore
#endif

final class W20SquirrelHooks {
    static let shared = W20SquirrelHooks()

    private(set) var panel: W20MemoryPanel?

    private init() {}

    /// 按键拦截（SquirrelInputController.handle() 调用）：⌥M 唤起/收起记忆管理浮层。
    /// 返回 true = 事件被消费（不进 rime、不给客户端）。
    func intercept(event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 0x2E,  // M
           event.modifierFlags.contains(.option) {
            togglePanel()
            return true
        }
        return false
    }

    func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if panel == nil {
            panel = W20MemoryPanel(
                store: W20MemoryStore(),
                breaker: W20SquirrelBreaker(),
                engine: W20CppProposalEngine())  // 提案卡接 C++ Null 提案桩
        }
        panel?.show()
    }

    /// 提案卡演示（菜单项「提案卡演示」）。
    func showProposalDemo() {
        showPanel()
    }
}

// MARK: - 熔断同源（W12EventBridge / ContextCore CircuitBreaker，跨进程持久）

/// 包一层 W12EventBridge 的 CircuitBreaker（store meta `breaker`），
/// 记忆界面「一键熔断开关」与采集链路共用同一熔断态。
final class W20SquirrelBreaker: W20BreakerControl {
    private var breaker: CircuitBreaker { W12EventBridge.shared.breaker }
    var isTripped: Bool {
        breaker.refresh()
        return breaker.isTripped
    }
    func trip() { breaker.trip() }
    func reset() { breaker.reset() }
}

// MARK: - 提案引擎：C++ Null 提案桩（ObjC++ 桥）

/// 驱动 **C++ NullProposalAgent**（ai/backends/null/null_proposal_agent.cc）：
/// 与 ai/ 单测同一个桩，同一流式提案/红线/状态流转语义。
final class W20CppProposalEngine: W20ProposalEngine {
    private let bridge = W20ProposalBridge.shared()

    func propose(secureInput: Bool) -> [W20ProposalItem] {
        bridge.proposeSecure(secureInput).map {
            W20ProposalItem(
                id: $0.proposalId,
                kind: W20ProposalKind(rawValue: $0.kind) ?? .plan,
                title: $0.title,
                detail: $0.detail,
                actions: $0.actions.map {
                    W20ProposalAction(id: $0.actionId, title: $0.title,
                                      detail: $0.detail)
                })
        }
    }

    func confirm(proposalID: String) -> W20ExecHandle {
        let h = bridge.confirm(proposalID)
        return W20ExecHandle(
            id: h.execId, proposalID: h.proposalId,
            state: W20ExecState(rawValue: h.state) ?? .failed,
            progress: h.progress, result: h.result)
    }

    func observe(_ handle: W20ExecHandle,
                 onUpdate: @escaping (W20ExecHandle) -> Void) -> Bool {
        let objcHandle = W20BExecHandle()
        objcHandle.execId = handle.id
        objcHandle.proposalId = handle.proposalID
        objcHandle.state = handle.state.rawValue
        objcHandle.progress = handle.progress
        objcHandle.result = handle.result
        return bridge.observe(objcHandle) { snap in
            guard let snap else { return }
            onUpdate(W20ExecHandle(
                id: snap.execId, proposalID: snap.proposalId,
                state: W20ExecState(rawValue: snap.state) ?? .failed,
                progress: snap.progress, result: snap.result))
        }
    }
}
#endif  // !W20_STANDALONE
