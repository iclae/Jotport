#if os(macOS)
import AppKit

enum ScratchpadStyle {
    static func adaptive(_ hex: Int, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua { return dark }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
    static let background = adaptive(0xFDFDFD, dark: .windowBackgroundColor)
    static let foreground = adaptive(0x222832, dark: .labelColor)
    static let secondary = adaptive(0x5B6470, dark: .secondaryLabelColor)
    static let divider = adaptive(0xE6E9EE, dark: .separatorColor)
    static let action = adaptive(0x2856A3, dark: .systemBlue)
    static let actionTint = adaptive(0xF0F4FD, dark: .controlBackgroundColor)
}

/// A native, on-demand search surface; composition owns Escape until it commits/cancels.
final class ScratchpadSearch: NSObject, NSSearchFieldDelegate {
    let field = NSSearchField()
    let includeArchived = NSButton(checkboxWithTitle: "包含归档", target: nil, action: nil)
    let view = NSStackView()
    var changed: (() -> Void)?
    var closed: (() -> Void)?
    var isOpen: Bool { !view.isHidden }

    override init() {
        super.init()
        field.placeholderString = "搜索笔记、概况或会话 ID"
        field.setAccessibilityLabel("搜索笔记")
        field.delegate = self
        field.target = self
        field.action = #selector(update)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        includeArchived.target = self
        includeArchived.action = #selector(update)
        includeArchived.font = .systemFont(ofSize: 11)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.addArrangedSubview(field)
        view.addArrangedSubview(includeArchived)
        field.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        view.isHidden = true
    }

    func open(in window: NSWindow) {
        view.isHidden = false
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    @discardableResult func close(composing: Bool = false) -> Bool {
        guard isOpen, !composing else { return false }
        field.stringValue = ""
        includeArchived.state = .off
        view.isHidden = true
        changed?()
        closed?()
        return true
    }

    @objc private func update() { changed?() }
    func controlTextDidChange(_ obj: Notification) { changed?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        return close(composing: textView.hasMarkedText())
    }
}
#endif
