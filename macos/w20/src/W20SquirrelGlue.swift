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
import CoreGraphics
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
                engine: W20CppProposalEngine(),  // 提案卡接 C++ Null 提案桩
                c1Control: W20SquirrelC1Control(),  // W27：C1 开关 + 状态显示
                screenControl: W20SquirrelScreenControl(),  // W32：读屏显式开关（默认关）
                retentionControl: W20SquirrelRetentionControl(),  // W29：记录我的回复开关
                modelControl: W20ModelServiceControl())  // W30：本地模型（7B）显式开关（不开不加载）
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

// MARK: - C1 开关同源（W12Privacy/W12C1Collector，⌥M 浮层 C1 开关与状态显示）

/// W27：⌥M 管理浮层「C1 屏幕/语音采集」开关的数据源——与采集链路共用
/// W12Privacy 显式开关（store meta `c1_enabled`，跨进程持久，默认关）。
/// 确认文案 = W12Privacy.consentText（用途/范围/随时可关）；关闭即清屏幕上下文。
final class W20SquirrelC1Control: W20C1Control {
    var isC1Enabled: Bool {
        W12Privacy.isC1ExplicitlyEnabled(store: W12EventBridge.shared.store)
            || W12Settings.load().c1Enabled
    }
    var consentText: String { W12Privacy.consentText }
    var statusText: String {
        let s = W12Settings.load()
        if isC1Enabled {
            var parts: [String] = []
            if s.c1Screen || W12Privacy.isC1ScreenEnabled(store: W12EventBridge.shared.store) {
                parts.append("屏幕")
            }
            if s.c1Audio { parts.append("语音") }
            return "C1：开（\(parts.isEmpty ? "无子项" : parts.joined(separator: "+"))，仅输入时，防抖 \(Int(s.debounceSeconds))s）"
        }
        return "C1：关（默认，未采集）"
    }
    @discardableResult
    func setEnabled(_ on: Bool, explicitConfirm: Bool) -> Bool {
        if on {
            return W12Privacy.enableC1(
                store: W12EventBridge.shared.store, explicitConfirm: explicitConfirm)
        }
        W12Privacy.disableC1(store: W12EventBridge.shared.store)
        return true
    }
}

// MARK: - W32 读屏开关同源（W12Privacy c1_screen / W12ScreenGate，⌥M「读取屏幕内容以增强候选」）

/// W32：⌥M 管理浮层「读取屏幕内容以增强候选（需授权）」开关的数据源——与采集链路共用
/// W12Privacy 持久开关（store meta `c1_screen`，跨进程持久，**默认关**）。
/// 硬规则：`setEnabled(true)` 是 **CGRequestScreenCaptureAccess 一次性授权请求的唯一
/// 发起点**（弹系统 TCC 确认框）；平时按键采集只 CGPreflightScreenCaptureAccess 探活，
/// 未授权跳过读屏 + 状态行「读屏未授权」，打字/语音路径绝不自动发起请求。
final class W20SquirrelScreenControl: W20ScreenContextControl {
    var isScreenEnabled: Bool {
        W12Privacy.isC1ScreenEnabled(store: W12EventBridge.shared.store)
            || W12Settings.load().c1Screen
    }
    var statusText: String {
        W12ScreenGate.statusText(
            screenSwitchOn: isScreenEnabled,
            screenAuthorized: CGPreflightScreenCaptureAccess())
    }
    @discardableResult
    func setEnabled(_ on: Bool, explicitConfirm: Bool) -> Bool {
        guard explicitConfirm else { return false }
        if on {
            W12Privacy.enableC1Screen(
                store: W12EventBridge.shared.store, explicitConfirm: true)
            // 一次性授权请求（唯一发起点；已授权/已拒绝时 CGRequest 立即返回不重复弹窗）
            _ = W12ScreenAccess.live().requestAccess()
            return true
        }
        W12Privacy.disableC1Screen(store: W12EventBridge.shared.store)
        return true
    }
}

// MARK: - 留存开关同源（W12Privacy 上屏文本留存 L3，⌥M「记录我的回复」开关）

/// W29：⌥M 管理浮层「记录我的回复（用于记忆与推荐）」开关的数据源——与事件留存链路
/// 共用 W12Privacy 持久开关（store meta `commit_text_retention`，跨进程持久，默认关）。
/// 确认文案 = W12Privacy.retentionConsentText（留存什么/干嘛用/本地存储/随时可关/
/// 清空连事件一起）；关闭后新事件 text_out 不再留存（密码框/安全输入恒不记录不变）。
final class W20SquirrelRetentionControl: W20RetentionControl {
    var isRetentionEnabled: Bool {
        W12Privacy.isCommitTextRetentionEnabled(store: W12EventBridge.shared.store)
    }
    var consentTitle: String { W12Privacy.retentionConsentTitle }
    var consentText: String { W12Privacy.retentionConsentText }
    var statusText: String {
        isRetentionEnabled
            ? "留存：开（新上屏回复入本地记忆，供回忆与推荐）"
            : "留存：关（默认，回复不落库、配对无 my_reply）"
    }
    @discardableResult
    func setEnabled(_ on: Bool, explicitConfirm: Bool) -> Bool {
        if on {
            return W12Privacy.enableCommitTextRetention(
                store: W12EventBridge.shared.store, explicitConfirm: explicitConfirm)
        }
        W12Privacy.disableCommitTextRetention(store: W12EventBridge.shared.store)
        return true
    }
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
