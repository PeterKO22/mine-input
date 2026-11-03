import AppKit

#if canImport(ContextCore)
import ContextCore
#endif

/// ⌥Esc 提词浮层（任务书 (c)）：NSPanel 浮层 + SSE 流式建议实时刷新 +
/// Tab/点按采纳（suggestion_feedback 入库）。
///
/// 形态：非激活浮层面板（不抢焦点，「只建议不上屏」——未采纳前绝不 commit）；
/// 流式数据来自 W12PrompterModel（Hub/Null 双模），每帧 Δ 到达即重绘列表。
/// 键盘（Tab/数字/Esc）由 Squirrel handle() 拦截转发（W12SquirrelGlue），
/// 点按采纳走面板按钮。真实 GUI 行为需人工实测（本环境禁 computer_use），
/// 流式刷新与采纳语义已由脚本化实测覆盖（w12ctl prompter）。
public final class W12PrompterOverlay {
    public var onAdopt: ((Candidate, Int) -> Void)?
    public var onClose: (() -> Void)?

    public private(set) var model = W12PrompterModel()
    private var panel: NSPanel?
    private var stack: NSStackView?
    private var statusLabel: NSTextField?
    private var backend: SuggestBackend = NullSuggestBackend()
    private var ctx = SuggestContext(beforeCursor: "")
    private var streamTask: Task<Void, Never>?

    public init() {}

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// 唤起/收起（⌥Esc 感应点：IME 热键，README「⌥Esc 感应点」表 #2）。
    public func toggle(beforeCursor: String, appId: String, fromVoice: Bool,
                       backend: SuggestBackend, timeout: TimeInterval = 0.8) {
        if isVisible {
            close()
        } else {
            show(beforeCursor: beforeCursor, appId: appId, fromVoice: fromVoice,
                 backend: backend, timeout: timeout)
        }
    }

    public func show(beforeCursor: String, appId: String, fromVoice: Bool,
                     backend: SuggestBackend, timeout: TimeInterval = 0.8) {
        model = W12PrompterModel()
        self.backend = backend
        ctx = SuggestContext(beforeCursor: beforeCursor, appId: appId, fromVoice: fromVoice)
        ensurePanel()
        panel?.orderFrontRegardless()
        refreshPanel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.model.run(ctx: self.ctx, backend: backend, timeout: timeout) { _ in
                DispatchQueue.main.async { self.refreshPanel() }
            }
            DispatchQueue.main.async { self.refreshPanel() }
        }
    }

    public func close() {
        streamTask?.cancel()
        panel?.orderOut(nil)
        onClose?()
    }

    /// Tab 采纳（默认第 1 条；数字选中后采纳选中条）——采纳后写回客户端上屏 + feedback 入库。
    @discardableResult
    public func adopt(index: Int = 0) -> Candidate? {
        guard let chosen = model.adopt(index: index, textIn: ctx.beforeCursor, appId: ctx.appId) else {
            return nil
        }
        close()
        return chosen
    }

    // MARK: 面板

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = NSColor(
            srgbRed: 0.055, green: 0.161, blue: 0.141, alpha: 0.96)  // design-language bg #0E2924
        p.hasShadow = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let title = NSTextField(labelWithString: "⌥Esc 提词（Tab 采纳 · Esc 关闭）")
        title.textColor = NSColor(srgbRed: 0.831, green: 0.659, blue: 0.341, alpha: 1) // 金 #D4A857
        title.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        stack.addArrangedSubview(title)

        let status = NSTextField(labelWithString: "流式建议实时刷新中…")
        status.textColor = NSColor(srgbRed: 0.220, green: 0.541, blue: 0.514, alpha: 1) // 青 #388A83
        status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        stack.addArrangedSubview(status)
        statusLabel = status

        p.contentView = stack
        self.stack = stack
        self.panel = p
    }

    /// 每帧 Δ 到达后重绘（实时刷新）。
    public func refreshPanel() {
        guard let stack else { return }
        // 保留前两个子视图（标题 + 状态行），重建候选按钮
        while stack.arrangedSubviews.count > 2 {
            let v = stack.arrangedSubviews[2]
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (i, c) in model.candidates.enumerated() {
            let b = NSButton(title: "\(i + 1). \(c.text)  (\(String(format: "%.2f", c.score)) \(c.source))",
                             target: self, action: #selector(candidateClicked(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            b.contentTintColor = NSColor.labelColor
            stack.addArrangedSubview(b)
        }
        if let last = model.refreshLog.last {
            statusLabel?.stringValue = last
        }
        panel?.setContentSize(stack.fittingSize)
    }

    @objc private func candidateClicked(_ sender: NSButton) {
        if let chosen = adopt(index: sender.tag) {
            onAdopt?(chosen, sender.tag)
        }
    }
}
