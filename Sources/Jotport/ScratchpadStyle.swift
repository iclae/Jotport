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

final class ScratchpadWindow: NSWindow {
    var closeSearch: (() -> Bool)?
    var searchIsOpen: (() -> Bool)?
    private(set) var routingCompositionEscape = false
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, searchIsOpen?() == true {
            if let text = firstResponder as? NSTextView, text.hasMarkedText() {
                routingCompositionEscape = true
                defer { routingCompositionEscape = false }
                super.sendEvent(event)
                return
            }
            if closeSearch?() == true { return }
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) {
        if routingCompositionEscape || (firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        if closeSearch?() != true { super.cancelOperation(sender) }
    }
}

final class TitleRail: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func layout() {
        super.layout()
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(kind), let container = button.superview else { continue }
            let center = container.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: self)
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: center.y - button.frame.height / 2))
        }
    }
}

final class WindowPinButton: NSButton {
    func synchronize(with window: NSWindow) {
        let pinned = window.level == .floating
        state = pinned ? .on : .off
        let label = pinned ? "取消窗口置顶" : "置顶窗口"
        let symbol = pinned ? "pin.fill" : "pin"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        identifier = NSUserInterfaceItemIdentifier(symbol)
        contentTintColor = pinned ? ScratchpadStyle.action : ScratchpadStyle.secondary
        toolTip = label
        setAccessibilityLabel(label)
    }
    func toggle(window: NSWindow) {
        window.level = window.level == .floating ? .normal : .floating
        synchronize(with: window)
    }
}

final class SearchSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ScratchpadStyle.actionTint.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        ScratchpadStyle.action.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class AttentionButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        ScratchpadStyle.actionTint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        super.draw(dirtyRect)
    }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: max(25, size.height))
    }
}

/// A native, on-demand search surface; composition owns Escape until it commits/cancels.
final class ScratchpadSearch: NSObject, NSSearchFieldDelegate {
    let field = NSSearchField()
    let includeArchived = NSButton(checkboxWithTitle: "包含归档", target: nil, action: nil)
    let view = SearchSurface()
    let closeButton = NSButton(title: "esc", target: nil, action: nil)
    var visibilityChanged: ((Bool) -> Void)?
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
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        magnifier.contentTintColor = ScratchpadStyle.action
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(magnifier)
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 14)
        closeButton.bezelStyle = .smallSquare
        closeButton.controlSize = .small
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.toolTip = "关闭搜索（Esc）"
        closeButton.setAccessibilityLabel("关闭搜索")
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        for item in [field, closeButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 40),
            magnifier.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            magnifier.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 14),
            magnifier.heightAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 34)
        ])
        view.isHidden = true
    }

    func open(in window: NSWindow) {
        view.isHidden = false
        visibilityChanged?(true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    @discardableResult func close(composing: Bool = false) -> Bool {
        guard isOpen, !composing else { return false }
        field.stringValue = ""
        includeArchived.state = .off
        field.window?.makeFirstResponder(nil)
        view.isHidden = true
        visibilityChanged?(false)
        changed?()
        closed?()
        return true
    }

    @objc private func dismiss() { close() }

    @objc private func update() { changed?() }
    func controlTextDidChange(_ obj: Notification) { changed?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        return close(composing: textView.hasMarkedText() || (textView.window as? ScratchpadWindow)?.routingCompositionEscape == true)
    }
}
#endif
