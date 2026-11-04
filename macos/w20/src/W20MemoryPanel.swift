// W20MemoryPanel.swift — 记忆管理界面（N8，docs/技术方案-v0.4.md §15.3）
//
// macOS 浮层入口（⌥M / 菜单项「记忆管理…」，见 W20SquirrelGlue）：
//   - 顶部常显：采集状态（采集中 / 已熔断）+ 一键熔断开关（CircuitBreaker 同源，
//     W19「熔断停记」/W12 熔断联动）+ 今日/累计条数；
//   - 时间线按日分组（YYYY-MM-DD）→ 单条查看/编辑 situation（before_cursor / thread）
//     与 my_reply（text）、删除（物理移除）、搜索、导出（JSONL）；
//   - 提案卡（任务书 (d)）：方案卡 + 显式「确认执行」，接 Null 桩演示 state 流转。
//
// 数据操作全部走 W20MemoryStore（脚本化可验：w20ctl）；本文件只做 AppKit 呈现。
// 视觉：design/design-language.md 深色科幻（bg/card/stroke、gold 主强调、cyan 次强调、
// red 熔断/危险、green 完成；数值 mono 微发光）。
import AppKit
import UniformTypeIdentifiers

public final class W20MemoryPanel: NSObject {
    private let store: W20MemoryStore
    private let breaker: W20BreakerControl?
    private let engine: W20ProposalEngine

    private var panel: NSPanel?
    private var filtered: [W20MemoryEntry] = []
    private var selectedID: String?

    // 顶部常显
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let breakerSwitch = NSSwitch()
    private let breakerLabel = NSTextField(labelWithString: "一键熔断")

    // 记忆时间线
    private let searchField = NSSearchField()
    private let timelineStack = NSStackView()
    private let beforeCursorView = NSTextView()
    private let threadView = NSTextView()
    private let replyView = NSTextView()
    private let detailMeta = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private let exportOneButton = NSButton(title: "", target: nil, action: nil)
    private let exportAllButton = NSButton(title: "", target: nil, action: nil)

    // 提案卡
    private var proposalCard: W20ProposalCardView?
    private let tabControl = NSSegmentedControl()

    public init(store: W20MemoryStore, breaker: W20BreakerControl?,
                engine: W20ProposalEngine) {
        self.store = store
        self.breaker = breaker
        self.engine = engine
        super.init()
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: 呈现

    public func toggle() {
        if isVisible { close() } else { show() }
    }

    public func show() {
        ensurePanel()
        refreshAll()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        panel?.orderOut(nil)
    }

    // MARK: 面板搭建

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        p.title = "记忆管理 · 提炼输入法"
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.minSize = NSSize(width: 760, height: 480)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 640))
        root.wantsLayer = true
        root.layer?.backgroundColor = W20Color.bg.cgColor

        // ---- 顶部常显：采集状态 + 一键熔断 ----
        let topBar = NSView()
        topBar.w20Card(cornerRadius: 8)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.borderWidth = 0
        statusLabel.font = W20Font.body()
        statusLabel.textColor = W20Color.titleText
        countsLabel.font = W20Font.mono(11)
        countsLabel.textColor = W20Color.gold
        breakerLabel.font = W20Font.body()
        breakerLabel.textColor = W20Color.dimText
        breakerSwitch.target = self
        breakerSwitch.action = #selector(onBreakerToggled)

        let topRow = NSStackView(views: [
            statusDot, statusLabel, countsLabel, NSView(), breakerLabel, breakerSwitch,
        ])
        topRow.orientation = .horizontal
        topRow.spacing = 10
        topRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // ---- 分段：记忆时间线 / 提案卡 ----
        tabControl.segmentCount = 2
        tabControl.setLabel("记忆时间线", forSegment: 0)
        tabControl.setLabel("提案卡", forSegment: 1)
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(onTabChanged)

        // ---- 记忆时间线页 ----
        let memoryPage = buildMemoryPage()

        // ---- 提案卡页 ----
        let card = W20ProposalCardView(engine: engine)
        proposalCard = card
        let proposalScroll = NSScrollView()
        proposalScroll.drawsBackground = false
        proposalScroll.hasVerticalScroller = true
        embedInScroll(card, in: proposalScroll)
        let proposalPage = proposalScroll

        // ---- 组装 ----
        for v in [topBar, tabControl, memoryPage, proposalPage] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            tabControl.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            tabControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            memoryPage.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12),
            memoryPage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            memoryPage.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            memoryPage.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            proposalPage.topAnchor.constraint(equalTo: memoryPage.topAnchor),
            proposalPage.leadingAnchor.constraint(equalTo: memoryPage.leadingAnchor),
            proposalPage.trailingAnchor.constraint(equalTo: memoryPage.trailingAnchor),
            proposalPage.bottomAnchor.constraint(equalTo: memoryPage.bottomAnchor),
        ])

        // topBar 内部
        topBar.addSubview(topRow)
        topRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: topBar.topAnchor),
            topRow.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topRow.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        p.contentView = root
        p.center()
        panel = p
        applyTab()
    }

    private func buildMemoryPage() -> NSView {
        // 搜索行
        searchField.placeholderString = "搜索 situation / my_reply…"
        searchField.font = W20Font.body()
        searchField.delegate = self
        searchField.wantsLayer = true
        searchField.layer?.backgroundColor = W20Color.card.cgColor
        searchField.layer?.cornerRadius = 4
        searchField.layer?.borderColor = W20Color.stroke.cgColor
        searchField.layer?.borderWidth = 1

        W20Style.secondaryButton(exportAllButton, title: "导出…")
        exportAllButton.target = self
        exportAllButton.action = #selector(onExportAll)
        let searchRow = NSStackView(views: [searchField, exportAllButton])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8

        // 左：时间线（按日分组）
        timelineStack.orientation = .vertical
        timelineStack.alignment = .leading
        timelineStack.spacing = 6
        timelineStack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        let timelineScroll = NSScrollView()
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.w20Card()
        embedInScroll(timelineStack, in: timelineScroll)
        timelineScroll.widthAnchor.constraint(equalToConstant: 330).isActive = true

        // 右：详情（查看/编辑）
        func editor(_ tv: NSTextView, height: CGFloat) -> NSScrollView {
            tv.font = W20Font.body()
            tv.textColor = W20Color.bodyText
            tv.backgroundColor = W20Color.bg
            tv.isRichText = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = true
            tv.minSize = NSSize(width: 0, height: height)
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
            tv.wantsLayer = true
            tv.layer?.cornerRadius = 4
            tv.layer?.borderColor = W20Color.stroke.cgColor
            tv.layer?.borderWidth = 1
            let s = NSScrollView()
            s.drawsBackground = false
            s.documentView = tv
            s.hasVerticalScroller = true
            s.translatesAutoresizingMaskIntoConstraints = false
            s.heightAnchor.constraint(equalToConstant: height).isActive = true
            return s
        }
        detailMeta.font = W20Font.dim()
        detailMeta.textColor = W20Color.dimText

        func sectionTitle(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = W20Font.dim()
            f.textColor = W20Color.gold
            return f
        }

        W20Style.primaryButton(saveButton, title: "保存修改")
        saveButton.target = self
        saveButton.action = #selector(onSave)
        W20Style.dangerButton(deleteButton, title: "删除")
        deleteButton.target = self
        deleteButton.action = #selector(onDelete)
        W20Style.secondaryButton(exportOneButton, title: "导出此条")
        exportOneButton.target = self
        exportOneButton.action = #selector(onExportOne)
        let buttonRow = NSStackView(views: [saveButton, deleteButton, exportOneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let detailStack = NSStackView(views: [
            detailMeta,
            sectionTitle("情境 situation · before_cursor"),
            editor(beforeCursorView, height: 72),
            sectionTitle("情境 situation · thread（每行一条）"),
            editor(threadView, height: 96),
            sectionTitle("我的回复 my_reply · text"),
            editor(replyView, height: 96),
            buttonRow,
        ])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let detailScroll = NSScrollView()
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.w20Card()
        embedInScroll(detailStack, in: detailScroll)
        detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        let split = NSStackView(views: [timelineScroll, detailScroll])
        split.orientation = .horizontal
        split.spacing = 12
        split.distribution = .fill
        timelineScroll.setContentHuggingPriority(.required, for: .horizontal)

        let page = NSStackView(views: [searchRow, split])
        page.orientation = .vertical
        page.spacing = 10
        page.translatesAutoresizingMaskIntoConstraints = false
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return page
    }

    /// NSScrollView + autolayout documentView 的标准嵌法（宽随 clip、纵向滚动）。
    private func embedInScroll(_ doc: NSView, in scroll: NSScrollView) {
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    // MARK: 数据刷新

    private func refreshAll() {
        refreshStatus()
        refreshTimeline()
        refreshDetail()
    }

    private func refreshStatus() {
        let s = store.collectionStatus(breaker: breaker)
        statusDot.layer?.backgroundColor =
            (s.breakerTripped ? W20Color.red : W20Color.cyan).cgColor
        statusLabel.stringValue = "采集状态：\(s.label)"
        countsLabel.stringValue = "今日 \(s.todayCount) 条 · 累计 \(s.totalCount) 条"
        breakerSwitch.state = s.breakerTripped ? .on : .off
    }

    private func refreshTimeline() {
        timelineStack.arrangedSubviews.forEach {
            timelineStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let kw = searchField.stringValue
        filtered = store.search(keyword: kw.isEmpty ? nil : kw)
        var lastDay = ""
        for e in filtered {
            let day = String(e.ts.prefix(10))
            if day != lastDay {
                lastDay = day
                let count = filtered.filter { String($0.ts.prefix(10)) == day }.count
                let h = NSTextField(labelWithString: "\(day) · \(count) 条")
                h.font = W20Font.mono(11)
                h.textColor = W20Color.gold
                timelineStack.addArrangedSubview(h)
            }
            timelineStack.addArrangedSubview(makeEntryRow(e))
        }
        if filtered.isEmpty {
            let empty = NSTextField(labelWithString: "（无记忆条目）")
            empty.font = W20Font.dim()
            empty.textColor = W20Color.dimText
            timelineStack.addArrangedSubview(empty)
        }
    }

    private func makeEntryRow(_ e: W20MemoryEntry) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(onEntryTapped(_:)))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.layer?.borderWidth = 1
        b.layer?.borderColor = W20Color.stroke.cgColor
        b.layer?.backgroundColor =
            (e.id == selectedID ? W20Color.card : NSColor.clear).cgColor
        if e.id == selectedID {
            b.layer?.borderColor = W20Color.gold.cgColor
        }
        b.tag = filtered.firstIndex(where: { $0.id == e.id }) ?? -1
        b.alignment = .left

        let ts = NSTextField(labelWithString: String(e.ts.prefix(19).replacingOccurrences(of: "T", with: " ")))
        ts.font = W20Font.mono(10)
        ts.textColor = W20Color.dimText
        let reply = NSTextField(labelWithString: e.myReply?.text ?? "（无回复）")
        reply.font = W20Font.body()
        reply.textColor = W20Color.bodyText
        reply.lineBreakMode = .byTruncatingTail
        reply.maximumNumberOfLines = 1
        let app = NSTextField(labelWithString: e.appId ?? "-")
        app.font = W20Font.dim()
        app.textColor = W20Color.cyan

        let row = NSStackView(views: [ts, reply, app])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: b.topAnchor),
            row.bottomAnchor.constraint(equalTo: b.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: b.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: b.trailingAnchor),
            b.widthAnchor.constraint(equalToConstant: 312),
        ])
        return b
    }

    private func refreshDetail() {
        guard let id = selectedID, let found = store.find(id: id) else {
            detailMeta.stringValue = "选择左侧条目查看/编辑（数据操作可用 w20ctl 脚本化验证）"
            beforeCursorView.string = ""
            threadView.string = ""
            replyView.string = ""
            return
        }
        let e = found.entry
        var chips: [String] = ["id \(e.id)", "ts \(e.ts)"]
        if let a = e.appId { chips.append("app \(a)") }
        if let c = e.consent { chips.append("consent \(c)") }
        if let m = e.myReply?.mode { chips.append("mode \(m)") }
        if let conf = e.meta?.confidence { chips.append(String(format: "conf %.2f", conf)) }
        detailMeta.stringValue = chips.joined(separator: "   ")

        beforeCursorView.string = e.situation?.beforeCursor ?? ""
        threadView.string = (e.situation?.thread ?? []).joined(separator: "\n")
        replyView.string = e.myReply?.text ?? ""
    }

    // MARK: 动作（数据操作 → W20MemoryStore）

    @objc private func onEntryTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < filtered.count else { return }
        selectedID = filtered[sender.tag].id
        refreshTimeline()
        refreshDetail()
    }

    @objc private func onSave() {
        guard let id = selectedID else { return }
        let thread = threadView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        _ = store.update(
            id: id,
            beforeCursor: beforeCursorView.string,
            thread: thread,
            replyText: replyView.string)
        refreshTimeline()
        refreshDetail()
    }

    @objc private func onDelete() {
        guard let id = selectedID else { return }
        let alert = NSAlert()
        alert.messageText = "删除该条记忆？"
        alert.informativeText = "删除即物理移除该行（不可恢复）。id \(id)"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.forEach {
            if $0.title == "删除" { $0.contentTintColor = W20Color.red }
        }
        if alert.runModal() == .alertFirstButtonReturn {
            _ = store.delete(id: id)
            selectedID = nil
            refreshTimeline()
            refreshDetail()
        }
    }

    @objc private func onExportOne() {
        guard let id = selectedID, let e = store.find(id: id)?.entry else { return }
        export(entries: [e])
    }

    @objc private func onExportAll() {
        export(entries: filtered)
    }

    private func export(entries: [W20MemoryEntry]) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json, .plainText]
        savePanel.nameFieldStringValue = "memory-export.jsonl"
        savePanel.begin { [weak self] resp in
            guard resp == .OK, let url = savePanel.url, let self else { return }
            try? self.store.export(entries: entries, to: url)
        }
    }

    @objc private func onBreakerToggled() {
        guard let breaker else { return }
        if breakerSwitch.state == .on {
            breaker.trip()   // 一键熔断：立即停采集
        } else {
            breaker.reset()
        }
        refreshStatus()
    }

    @objc private func onTabChanged() {
        applyTab()
    }

    private func applyTab() {
        // proposalCard / memoryPage 的显隐由 subview 顺序管理；简化：切页即重建
        guard let root = panel?.contentView else { return }
        let memoryPage = root.subviews.first { $0 is NSStackView }
        _ = memoryPage  // （两页同时在层内，见 ensurePanel 的约束；切换显示）
        let showProposal = tabControl.selectedSegment == 1
        proposalCard?.superview?.isHidden = !showProposal
        memoryPage?.isHidden = showProposal
    }

    // MARK: 脚本化可验：视图树 dump（w20ctl panel-dump）

    /// 导出界面关键文本（标题/状态/按钮/条目），供脚本化断言界面形态。
    public func debugDump() -> String {
        var lines: [String] = []
        func walk(_ v: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            if let f = v as? NSTextField {
                lines.append("\(pad)[text] \(f.stringValue)")
            } else if let b = v as? NSButton, !b.title.isEmpty {
                lines.append("\(pad)[button] \(b.title)")
            }
            for sub in v.subviews { walk(sub, depth: depth + 1) }
        }
        if let root = panel?.contentView { walk(root, depth: 0) }
        return lines.joined(separator: "\n")
    }
}

extension W20MemoryPanel: NSSearchFieldDelegate, NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        refreshTimeline()
    }
}
