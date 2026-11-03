// W12SquirrelGlue.swift —— W12 在 Squirrel/IMK 侧的接线（仅编进 Squirrel，
// SwiftPM 独立构建以 W12_STANDALONE 排除——SquirrelInputController 只存在于 app 目标）。
//
// 职责（任务书 b/c/d）：
//   (b) W7×W9 接线：输入会话 / 语音会话 / 候选选择事件 → W12EventBridge → InteractionStore；
//   (c) ⌥Esc 提词浮层：热键唤起 NSPanel 流式建议（W9 SuggestClient，Hub/Null 双模）→
//       实时刷新 → Tab/点按采纳（suggestion_feedback 入库 + 写回客户端上屏）；
//   (d) 隐私设置：C1 开关显式（W12Privacy/W12Config）；安全输入（IsSecureEventInputEnabled）
//       自动停；状态条指示色约定见 W12StatusColor。
#if !W12_STANDALONE
import AppKit
import Carbon
import Foundation

final class W12SquirrelHooks {
    static let shared = W12SquirrelHooks()

    let overlay = W12PrompterOverlay()
    private let c1 = W12C1Collector.shared
    /// 语音上屏经 w7CommitVoiceText 已报 voice_session，抑制随后 commit 的 key_session 双报。
    private var skipNextCommitReport = false

    private init() {}

    // MARK: 按键拦截（SquirrelInputController.handle() 调用）

    /// 返回 true = 事件被 W12 消费（不进 rime / 不给客户端）。
    func intercept(event: NSEvent, controller: SquirrelInputController,
                   preedit: String, appId: String) -> Bool {
        // ⌥Esc：唤起/收起提词浮层（FR5 感应点 #2；README「⌥Esc 感应点」表）
        if event.type == .keyDown, event.keyCode == 0x35,
           event.modifierFlags.contains(.option) {
            togglePrompter(controller: controller, preedit: preedit, appId: appId)
            return true
        }

        // 浮层打开：Tab 采纳 / 数字选中 / Esc 关闭（不抢焦点，未采纳不上屏）
        if overlay.isVisible, event.type == .keyDown {
            switch Int(event.keyCode) {
            case 0x30:  // Tab → 采纳第 1 条
                adoptIntoClient(controller: controller, index: 0)
                return true
            case 0x12...0x1C:  // 数字 1..9（ANSI 键码 18..28）
                let digit = [0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x16: 5,
                             0x1A: 6, 0x1C: 7, 0x19: 8, 0x1D: 9][Int(event.keyCode)] ?? 0
                if digit > 0 {
                    adoptIntoClient(controller: controller, index: digit - 1)
                    return true
                }
            case 0x35:  // Esc → 关闭浮层
                overlay.close()
                return true
            default:
                break
            }
        }

        // C1 输入触发（仅输入时 + 防抖 2s；密码框 IsSecureEventInputEnabled 自动停）
        if event.type == .keyDown {
            c1.noteKeystroke(
                appId: appId,
                secureInput: IsSecureEventInputEnabled(),
                completion: nil)
        }
        return false
    }

    // MARK: ⌥Esc 浮层

    func togglePrompter(controller: SquirrelInputController, preedit: String, appId: String) {
        let settings = W12Settings.load()
        guard settings.prompterEnabled else { return }
        let backend: SuggestBackend = settings.prompterBackend == "hub"
            ? HubSuggestBackend(
                baseURL: URL(string: settings.hubBaseURL)!,
                token: ProcessInfo.processInfo.environment["MINE_HUB_TOKEN"] ?? "")
            : NullSuggestBackend()
        overlay.onAdopt = { chosen, _ in
            controller.w12CommitAdopted(chosen.text)  // 采纳才上屏（model 已入库 feedback）
        }
        overlay.toggle(
            beforeCursor: preedit, appId: appId,
            fromVoice: W7PttController.shared.isCapturing,
            backend: backend)
    }

    private func adoptIntoClient(controller: SquirrelInputController, index: Int) {
        guard let chosen = overlay.adopt(index: index) else { return }
        controller.w12CommitAdopted(chosen.text)
    }

    // MARK: W7×W9 事件上报（SquirrelInputController 调用点转发）

    /// 输入会话（commit 上屏）。textIn=输入串；textOut=上屏文本（留存默认关 → 落库空）。
    func noteCommit(textIn: String, textOut: String, appId: String) {
        if skipNextCommitReport {
            skipNextCommitReport = false  // 语音上屏已报 voice_session，避免双报
            return
        }
        c1.bridge.reportKeySession(
            textIn: textIn, textOut: textOut,
            appId: appId, secureInput: IsSecureEventInputEnabled())
    }

    /// 候选选择（candidate_pick）。
    func noteCandidatePick(textIn: String, textOut: String, appId: String) {
        c1.bridge.reportCandidatePick(
            textIn: textIn, textOut: textOut,
            appId: appId, secureInput: IsSecureEventInputEnabled())
    }

    /// 语音会话（PTT 转写上屏）：事件上报 + C1 asr_digest（开时附摘要）。
    func noteVoiceCommit(text: String, appId: String) {
        skipNextCommitReport = true
        c1.notePttTranscript(
            text, appId: appId, secureInput: IsSecureEventInputEnabled())
    }

    /// PTT 窗口（W7PttController.start/stop 调用）：C1 仅输入时触发的语音窗。
    func notePttStart() { c1.notePttStart() }
    func notePttEnd() { c1.notePttEnd() }
}
#endif
