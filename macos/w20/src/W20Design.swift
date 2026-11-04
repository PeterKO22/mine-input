// W20Design.swift — 深色科幻视觉 token（唯一风格源 design/design-language.md）
//
// 色板/层级/几何逐条取自 design-language §1–§3：bg #0E2924、card #18352F、
// stroke #2B4B44、gold #D4A857（主强调）、cyan #388A83（次强调）、red #A84B3D
// （危险/熔断）、green #4CB368（成功）；文字层级 #E0E6E4/#C8D0CC/#8A9E99；
// 数值一律 mono + 微发光；圆角 8/6/4；描边 1px。
import AppKit

enum W20Color {
    static let bg = NSColor(srgbHex: 0x0E2924)
    static let card = NSColor(srgbHex: 0x18352F)
    static let stroke = NSColor(srgbHex: 0x2B4B44)
    static let gold = NSColor(srgbHex: 0xD4A857)
    static let cyan = NSColor(srgbHex: 0x388A83)
    static let purple = NSColor(srgbHex: 0x5D3D8C)
    static let red = NSColor(srgbHex: 0xA84B3D)
    static let green = NSColor(srgbHex: 0x4CB368)
    static let titleText = NSColor(srgbHex: 0xE0E6E4)
    static let bodyText = NSColor(srgbHex: 0xC8D0CC)
    static let dimText = NSColor(srgbHex: 0x8A9E99)
}

enum W20Font {
    /// 模块标题（14 Bold）。
    static func title() -> NSFont { .boldSystemFont(ofSize: 14) }
    /// 正文（12 Medium）。
    static func body() -> NSFont { .systemFont(ofSize: 12, weight: .medium) }
    /// 弱化/辅助（10 Regular）。
    static func dim() -> NSFont { .systemFont(ofSize: 10) }
    /// 数值强调（mono，微发光由调用侧 textShadow 处理）。
    static func mono(_ size: CGFloat = 12) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: .bold)
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

extension NSView {
    /// 卡片质感（card 填充 + stroke 1px 描边，圆角）。
    func w20Card(cornerRadius: CGFloat = 8) {
        wantsLayer = true
        layer?.backgroundColor = W20Color.card.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderColor = W20Color.stroke.cgColor
        layer?.borderWidth = 1
    }
}

enum W20Style {
    private static func styled(_ b: NSButton, title: String) {
        b.isBordered = false  // 自绘扁平按钮（design-language §4 形态）
        b.font = W20Font.body()
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: W20Font.body(),
        ])
    }

    /// 主按钮（实心暖金 + 微光晕 + 深色字，design-language §4）。
    static func primaryButton(_ b: NSButton, title: String) {
        styled(b, title: title)
        b.layer?.backgroundColor = W20Color.gold.cgColor
        b.layer?.borderWidth = 0
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: W20Color.bg, .font: W20Font.body(),
        ])
        b.shadow = NSShadow()
        b.shadow?.shadowColor = W20Color.gold.withAlphaComponent(0.35)
        b.shadow?.shadowOffset = .zero
        b.shadow?.shadowBlurRadius = 6
    }

    /// 次按钮（透明/深底 + 细描边 + 浅字）。
    static func secondaryButton(_ b: NSButton, title: String) {
        styled(b, title: title)
        b.layer?.backgroundColor = NSColor.clear.cgColor
        b.layer?.borderColor = W20Color.stroke.cgColor
        b.layer?.borderWidth = 1
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: W20Color.bodyText, .font: W20Font.body(),
        ])
    }

    /// 危险按钮（暗红填充 + 红描边，熔断/删除）。
    static func dangerButton(_ b: NSButton, title: String) {
        styled(b, title: title)
        b.layer?.backgroundColor = W20Color.red.cgColor
        b.layer?.borderColor = W20Color.red.cgColor
        b.layer?.borderWidth = 1
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: W20Color.titleText, .font: W20Font.body(),
        ])
    }

    /// 数值文本（gold mono + 微发光）。
    static func goldNumber(_ f: NSTextField, _ text: String) {
        f.stringValue = text
        f.font = W20Font.mono()
        f.textColor = W20Color.gold
        f.shadow = NSShadow()
        f.shadow?.shadowColor = W20Color.gold.withAlphaComponent(0.3)
        f.shadow?.shadowOffset = .zero
        f.shadow?.shadowBlurRadius = 3
    }
}
