// W20ProposalCard.swift — 提案卡 UI 形态（N7，任务书 (d)）
//
// 方案卡（标题 / 详情 / 动作清单）+ 显式「确认执行」按钮，接 Null 桩演示 state 流转
// （queued→running→done，进度/结果回填）。契约：ai/spi/ai_assist_v2.h（§15.2）。
//
// 红线（§15.2）：**「确认执行」按钮是 engine.confirm 的唯一调用点**——自动执行不存在；
// 确认后按钮禁用（不产生第二次执行），「重新提案」只重跑 propose（只提案，不执行）。
// 视觉：design/design-language.md（深色科幻：card/stroke/gold 主按钮/cyan 流转/
// green 完成/进度条金渐变 + 柔光）。
import AppKit

public final class W20ProposalCardView: NSView {
    private let engine: W20ProposalEngine

    private var proposal: W20ProposalItem?
    private var snapshots: [W20ExecHandle] = []
    private var replayIndex = 0
    private var replayTimer: Timer?

    // 视图
    private let kindChip = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let actionsStack = NSStackView()
    private let confirmButton = NSButton(title: "", target: nil, action: nil)
    private let reproposeButton = NSButton(title: "", target: nil, action: nil)
    private let stateChip = NSTextField(labelWithString: "")
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressFillWidth: NSLayoutConstraint!
    private let resultLabel = NSTextField(wrappingLabelWithString: "")

    public init(engine: W20ProposalEngine) {
        self.engine = engine
        super.init(frame: .zero)
        buildUI()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // MARK: 提案装载（只提案，不执行）

    /// 跑一轮 propose，填充方案卡。红线：propose 不得触发任何执行。
    public func reload() {
        snapshots = []
        replayTimer?.invalidate()
        let items = engine.propose(secureInput: false)
        proposal = items.first
        render()
    }

    // MARK: UI

    private func buildUI() {
        w20Card()
        titleLabel.font = W20Font.title()
        titleLabel.textColor = W20Color.gold
        detailLabel.font = W20Font.body()
        detailLabel.textColor = W20Color.bodyText
        detailLabel.maximumNumberOfLines = 4

        kindChip.font = W20Font.dim()
        kindChip.textColor = W20Color.cyan
        kindChip.wantsLayer = true
        kindChip.layer?.backgroundColor = W20Color.cyan.withAlphaComponent(0.15).cgColor
        kindChip.layer?.cornerRadius = 4
        kindChip.layer?.borderColor = W20Color.cyan.cgColor
        kindChip.layer?.borderWidth = 1

        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 8

        W20Style.primaryButton(confirmButton, title: "确认执行")
        confirmButton.target = self
        confirmButton.action = #selector(onConfirmTapped)  // confirm 的唯一调用点
        W20Style.secondaryButton(reproposeButton, title: "重新提案")
        reproposeButton.target = self
        reproposeButton.action = #selector(onReproposeTapped)

        stateChip.font = W20Font.mono(11)

        progressTrack.w20Card(cornerRadius: 4)
        progressTrack.layer?.backgroundColor = W20Color.bg.withAlphaComponent(0.6).cgColor
        progressFill.wantsLayer = true
        let grad = CAGradientLayer()
        grad.colors = [NSColor(srgbHex: 0x8A6B33).cgColor, W20Color.gold.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0.5)
        grad.endPoint = CGPoint(x: 1, y: 0.5)
        progressFill.layer = grad
        progressFill.layer?.cornerRadius = 3
        progressFill.layer?.shadowColor = W20Color.gold.cgColor
        progressFill.layer?.shadowOpacity = 0.5
        progressFill.layer?.shadowRadius = 4
        progressFill.layer?.shadowOffset = .zero

        resultLabel.font = W20Font.body()
        resultLabel.textColor = W20Color.green

        let buttonRow = NSStackView(views: [confirmButton, reproposeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let progressRow = NSStackView(views: [progressTrack, stateChip])
        progressRow.orientation = .horizontal
        progressRow.spacing = 8

        let stack = NSStackView(views: [
            titleLabel, kindChip, detailLabel, actionsStack,
            NSBox.separator(), buttonRow, progressRow, resultLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        progressTrack.addSubview(progressFill)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.translatesAutoresizingMaskIntoConstraints = false

        progressFillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressTrack.widthAnchor.constraint(equalToConstant: 260),
            progressTrack.heightAnchor.constraint(equalToConstant: 8),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressFillWidth,
        ])
    }

    private func render() {
        guard let p = proposal else {
            titleLabel.stringValue = "（无提案）"
            detailLabel.stringValue = "propose 未返回提案。"
            confirmButton.isEnabled = false
            return
        }
        titleLabel.stringValue = p.title
        kindChip.stringValue = "  \(p.kind.rawValue)  "
        detailLabel.stringValue = p.detail

        actionsStack.arrangedSubviews.forEach {
            actionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for a in p.actions {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let check = NSTextField(labelWithString: "○")  // 清单未执行形态
            check.font = W20Font.mono(12)
            check.textColor = W20Color.gold
            let t = NSTextField(labelWithString: a.title)
            t.font = W20Font.body()
            t.textColor = W20Color.titleText
            let d = NSTextField(labelWithString: a.detail)
            d.font = W20Font.dim()
            d.textColor = W20Color.dimText
            row.addArrangedSubview(check)
            row.addArrangedSubview(t)
            row.addArrangedSubview(d)
            actionsStack.addArrangedSubview(row)
        }

        confirmButton.isEnabled = true
        stateChip.stringValue = "待确认"
        stateChip.textColor = W20Color.dimText
        progressFillWidth.constant = 0
        resultLabel.stringValue = ""
    }

    // MARK: 确认执行（红线：用户显式动作 → engine.confirm 的唯一调用点）

    @objc private func onConfirmTapped() {
        guard let p = proposal else { return }
        // ↓ 全工程唯一 confirm 调用点：必须用户点击（无自动执行路径）。
        let handle = engine.confirm(proposalID: p.id)
        confirmButton.isEnabled = false  // 不产生第二次执行
        renderHandle(handle)
        if handle.state == .failed {
            resultLabel.textColor = W20Color.red
            resultLabel.stringValue = handle.result
            return
        }
        // 进度回填（observe）：收集快照后按节奏回放，演示 state 流转。
        snapshots = []
        _ = engine.observe(handle) { [weak self] snap in
            self?.snapshots.append(snap)
        }
        replayIndex = 0
        replayNext()
    }

    private func replayNext() {
        guard replayIndex < snapshots.count else { return }
        let snap = snapshots[replayIndex]
        replayIndex += 1
        renderHandle(snap)
        if replayIndex < snapshots.count {
            replayTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) {
                [weak self] _ in self?.replayNext()
            }
        }
    }

    private func renderHandle(_ h: W20ExecHandle) {
        switch h.state {
        case .queued:
            stateChip.stringValue = "queued"
            stateChip.textColor = W20Color.gold
        case .running:
            stateChip.stringValue = "running"
            stateChip.textColor = W20Color.cyan
        case .done:
            stateChip.stringValue = "done"
            stateChip.textColor = W20Color.green
            resultLabel.textColor = W20Color.green
            resultLabel.stringValue = h.result
        case .failed:
            stateChip.stringValue = "failed"
            stateChip.textColor = W20Color.red
            resultLabel.textColor = W20Color.red
            resultLabel.stringValue = h.result
        }
        progressFillWidth.constant = CGFloat(h.progress) * 260
    }

    @objc private func onReproposeTapped() {
        reload()  // 只重跑 propose：只提案，不执行
    }
}

private extension NSBox {
    /// 1px 分隔线（stroke 色，design-language §2）。
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.wantsLayer = true
        b.layer?.backgroundColor = W20Color.stroke.cgColor
        return b
    }
}
