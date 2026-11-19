#if os(macOS)
import AppKit
import JotportCore

final class BlockRowView: NSView, NSTextViewDelegate {
    let id: String
    var bodyChanged: ((String) -> Void)?
    var editingChanged: ((Bool) -> Void)?
    var performAction: ((BlockAction) -> Void)?

    private let editor = BlockTextView(fontSize: 14, placeholder: "输入正文")
    private let bodyUndo = UndoManager()
    private let recap = BlockTextView(fontSize: 13)
    private let recapRow = NSView()
    private let status = NSImageView()
    private let attention = NSButton(title: "◆ 待查看", target: nil, action: nil)
    private let reviewAction = AttentionButton()
    private let dragHandle: BlockDragHandle
    private let more = NSButton()
    private let hideRecap = NSButton()
    private let shortcutBar = NSVisualEffectView()
    private let shortcutStack = NSStackView()
    private let shortcutMenus = NSMenu()
    private let divider = NSBox()
    private var topSpacing: NSLayoutConstraint!
    private let marker = NSTextField(labelWithString: "")
    private var allActions: [BlockActionItem] = []
    private var shortcutActions: [BlockActionItem] = []
    private var canDrag = false
    private var dragging = false
    private var hovered = false
    private var shortcutsExpanded = false
    private var compactShortcuts: Bool?
    private var statusText: String?

    init(block: Block, dragHandle: BlockDragHandle) {
        id = block.id
        self.dragHandle = dragHandle
        super.init(frame: .zero)
        editor.focusChanged = { [weak self] in self?.showControls() }
        editor.delegate = self
        editor.allowsUndo = true
        editor.setAccessibilityLabel("块正文")
        editor.emphasizesFirstLine = true
        editor.string = block.body
        recap.isEditable = false
        recap.textColor = ScratchpadStyle.secondary
        recap.toolTip = "最近回复摘录，可能过期"
        recap.setAccessibilityLabel("最近回复摘录")
        status.setAccessibilityElement(true)
        status.isHidden = true
        status.imageScaling = .scaleProportionallyDown
        marker.font = .systemFont(ofSize: 11, weight: .medium)
        marker.textColor = ScratchpadStyle.secondary
        marker.isHidden = true

        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "块操作")
        more.imagePosition = .imageOnly
        more.imageScaling = .scaleProportionallyDown
        more.contentTintColor = .secondaryLabelColor
        more.isBordered = false
        more.target = self
        more.action = #selector(showMenu(_:))
        more.toolTip = "块操作"
        more.setAccessibilityLabel("块操作")
        hideRecap.title = "隐藏"
        hideRecap.bezelStyle = .inline
        hideRecap.target = self
        hideRecap.action = #selector(toggleRecap)
        hideRecap.setAccessibilityLabel("隐藏最近回复")
        hideRecap.isHidden = true

        attention.bezelStyle = .inline
        attention.isBordered = false
        attention.font = .systemFont(ofSize: 11, weight: .semibold)
        attention.contentTintColor = ScratchpadStyle.adaptive(0x8C4B00, dark: .systemOrange)
        attention.target = self
        attention.action = #selector(viewResult)
        attention.toolTip = "返回会话查看结果"
        attention.setAccessibilityLabel("结果待查看，返回会话")
        attention.isHidden = true
        reviewAction.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "返回会话")
        reviewAction.isBordered = false
        reviewAction.contentTintColor = ScratchpadStyle.action
        reviewAction.target = self
        reviewAction.action = #selector(viewResult)
        reviewAction.toolTip = "返回会话查看结果"
        reviewAction.setAccessibilityLabel("返回会话查看结果")
        reviewAction.isHidden = true
        editor.blockMenu = { [weak self] in self?.makeMenu() }
        let content = NSStackView(views: [marker, editor, recapRow, attention])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 3
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = ScratchpadStyle.divider
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        shortcutBar.material = .popover
        shortcutBar.blendingMode = .withinWindow
        shortcutBar.state = .active
        shortcutBar.wantsLayer = true
        shortcutBar.layer?.cornerRadius = 14
        shortcutBar.layer?.masksToBounds = true
        shortcutStack.spacing = 2
        shortcutBar.addSubview(shortcutStack)

        for view in [content, status, dragHandle, divider, shortcutBar, more, reviewAction] {
            addSubview(view)
        }
        recapRow.addSubview(recap)
        recapRow.addSubview(hideRecap)
        for view in [content, marker, editor, recapRow, recap, status, dragHandle, divider, shortcutBar, shortcutStack, more, hideRecap, reviewAction] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        topSpacing = content.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            topSpacing,
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
            reviewAction.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            reviewAction.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            reviewAction.widthAnchor.constraint(equalToConstant: 26),
            reviewAction.heightAnchor.constraint(equalToConstant: 26),
            editor.widthAnchor.constraint(equalTo: content.widthAnchor),
            recapRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            recap.leadingAnchor.constraint(equalTo: recapRow.leadingAnchor),
            recap.trailingAnchor.constraint(equalTo: recapRow.trailingAnchor, constant: -54),
            recap.topAnchor.constraint(equalTo: recapRow.topAnchor, constant: 2),
            recap.bottomAnchor.constraint(equalTo: recapRow.bottomAnchor),
            hideRecap.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            hideRecap.topAnchor.constraint(equalTo: recapRow.topAnchor, constant: 4),
            hideRecap.trailingAnchor.constraint(equalTo: recapRow.trailingAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -12),
            dragHandle.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            dragHandle.widthAnchor.constraint(equalToConstant: 18),
            dragHandle.heightAnchor.constraint(equalToConstant: 26),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            status.widthAnchor.constraint(equalToConstant: 17),
            status.heightAnchor.constraint(equalToConstant: 17),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            more.widthAnchor.constraint(equalToConstant: 29),
            more.heightAnchor.constraint(equalToConstant: 28),
            shortcutBar.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: 1),
            shortcutBar.centerYAnchor.constraint(equalTo: more.centerYAnchor),
            shortcutBar.heightAnchor.constraint(equalToConstant: 28),
            shortcutStack.leadingAnchor.constraint(equalTo: shortcutBar.leadingAnchor, constant: 5),
            shortcutStack.trailingAnchor.constraint(equalTo: shortcutBar.trailingAnchor, constant: -5),
            shortcutStack.centerYAnchor.constraint(equalTo: shortcutBar.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        let recapArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        recapRow.addTrackingArea(recapArea)
        let moreArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        more.addTrackingArea(moreArea)
        shortcutBar.addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        showControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ block: Block, actions: [BlockActionItem], shortcuts: [BlockAction], canDrag: Bool, dragging: Bool) {
        let blockMarkers = [block.pinned ? "置顶" : "", block.archived ? "已归档" : ""].filter { !$0.isEmpty }
        marker.stringValue = blockMarkers.joined(separator: " · ")
        marker.isHidden = blockMarkers.isEmpty

        let sessionStatus = block.association?.sessionID?.isEmpty == false ? block.run?.status : nil
        attention.isHidden = sessionStatus != "结果待查看"
        reviewAction.isHidden = attention.isHidden
        if statusText != sessionStatus {
            statusText = sessionStatus
            updateStatus()
        }
        if !block.recap.isEmpty {
            let excerpt = [block.recap, block.recapSource].filter { !$0.isEmpty }.joined(separator: "\n")
            if recap.string != excerpt { recap.string = excerpt }
        }
        recapRow.isHidden = block.recap.isEmpty || block.recapHidden == true
        allActions = actions
        let visible = shortcuts.compactMap { action in actions.first { $0.action == action } }
        if visible != shortcutActions {
            shortcutActions = visible
            compactShortcuts = nil
            updateShortcutButtons()
        }
        self.canDrag = canDrag
        setDragging(dragging)
    }

    func configureSpacing(top: CGFloat, last: Bool) {
        topSpacing.constant = top
        divider.isHidden = last
    }

    func focusBody() { window?.makeFirstResponder(editor) }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        if dragging { shortcutsExpanded = false }
        showControls()
    }

    func textDidBeginEditing(_ notification: Notification) { editingChanged?(true); showControls() }
    func textDidEndEditing(_ notification: Notification) {
        editingChanged?(false)
        DispatchQueue.main.async { [weak self] in self?.showControls() }
    }

    func textDidChange(_ notification: Notification) {
        bodyChanged?(editor.string)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { bodyUndo }

    override func layout() {
        super.layout()
        updateShortcutButtons()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovered = visibleRect.contains(point)
        if hovered && !dragging {
            let overMore = more.frame.contains(point)
            let insideShortcuts = shortcutsExpanded && shortcutBar.frame.insetBy(dx: -2, dy: 0).contains(point)
            shortcutsExpanded = overMore || insideShortcuts
        } else {
            shortcutsExpanded = false
        }
        hideRecap.isHidden = dragging || recapRow.isHidden || !recapRow.visibleRect.contains(recapRow.convert(point, from: self))
        showControls()
    }

    private func showControls() {
        let focused = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        more.isHidden = (!hovered && !focused) || dragging
        dragHandle.isHidden = !hovered || !canDrag || dragging
        shortcutBar.isHidden = more.isHidden || !shortcutsExpanded || shortcutActions.isEmpty
        if dragging || !hovered || recapRow.isHidden { hideRecap.isHidden = true }
    }

    private func updateShortcutButtons() {
        let textWidth = shortcutActions.reduce(CGFloat(10)) { width, item in
            width + (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width + 21
        }
        let compact = textWidth > bounds.width - 90
        guard compactShortcuts != compact else { return }
        compactShortcuts = compact
        for view in shortcutStack.arrangedSubviews { view.removeFromSuperview() }
        for item in shortcutActions {
            let button = NSButton(title: compact ? "" : item.title, target: self, action: #selector(chooseShortcut(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.toolTip = item.title
            button.setAccessibilityLabel(item.title)
            button.identifier = NSUserInterfaceItemIdentifier(item.action.rawValue)
            button.isEnabled = item.enabled
            if compact {
                button.image = NSImage(systemSymbolName: item.action.symbol, accessibilityDescription: item.title)
                button.imagePosition = .imageOnly
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            }
            shortcutStack.addArrangedSubview(button)
        }
    }

    private func makeMenu() -> NSMenu {
        shortcutMenus.removeAllItems()
        shortcutMenus.autoenablesItems = false
        for item in allActions {
            let menuItem = NSMenuItem(title: item.title, action: #selector(chooseMenuItem(_:)), keyEquivalent: "")
            menuItem.representedObject = item.action.rawValue
            menuItem.target = self
            menuItem.isEnabled = item.enabled
            if item.action == .remove { shortcutMenus.addItem(.separator()) }
            shortcutMenus.addItem(menuItem)
        }
        return shortcutMenus
    }

    @objc private func showMenu(_ sender: NSButton) {
        shortcutsExpanded = false
        showControls()
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
    }

    @objc private func chooseMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = BlockAction(rawValue: raw) else { return }
        performAction?(action)
    }

    @objc private func chooseShortcut(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = BlockAction(rawValue: raw) else { return }
        performAction?(action)
    }

    @objc private func viewResult() { performAction?(.start) }

    @objc private func toggleRecap() { performAction?(.toggleRecap) }

    private func updateStatus() {
        guard let statusText else {
            status.isHidden = true
            return
        }
        let symbol: String
        let color: NSColor
        switch statusText {
        case "启动中", "终端已执行启动脚本，等待会话。":
            (symbol, color) = ("hourglass", .secondaryLabelColor)
        case "待发送", "已打开，待粘贴", "空闲":
            (symbol, color) = ("text.cursor", .systemBlue)
        case "运行中":
            (symbol, color) = ("play.circle", .systemGreen)
        case "需要输入":
            (symbol, color) = ("exclamationmark.bubble", .systemOrange)
        case "结果待查看":
            (symbol, color) = ("checkmark.circle", .systemBlue)
        case "已退出":
            (symbol, color) = ("stop.circle", .secondaryLabelColor)
        case let value where value.hasPrefix("无法") || value.hasPrefix("打开") || value.hasPrefix("未确认"):
            (symbol, color) = ("xmark.octagon", .systemRed)
        default:
            (symbol, color) = ("questionmark.circle", .secondaryLabelColor)
        }
        status.isHidden = statusText == "结果待查看"
        status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        status.contentTintColor = color
        status.toolTip = statusText
        status.setAccessibilityLabel(statusText)
    }
}

private final class BlockTextView: NSTextView {
    private var height: CGFloat = 30
    private let placeholder: String?
    var blockMenu: (() -> NSMenu?)?
    var focusChanged: (() -> Void)?
    var emphasizesFirstLine = false
    private let storage: NSTextStorage

    init(fontSize: CGFloat, placeholder: String? = nil) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.storage = storage
        self.placeholder = placeholder
        super.init(frame: .zero, textContainer: container)
        font = .systemFont(ofSize: fontSize)
        textColor = ScratchpadStyle.foreground
        isRichText = false
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 3)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.focusChanged?() }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.focusChanged?() }
        return result
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        if let actions = blockMenu?() {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "块操作", action: nil, keyEquivalent: "")
            item.submenu = actions.copy() as? NSMenu
            menu.addItem(item)
        }
        return menu
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    override var string: String {
        didSet { updateHeight() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged { updateHeight() }
    }

    override func didChangeText() {
        super.didChangeText()
        updateHeight()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder, let font {
            (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
                .font: font, .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }

    private func updateHeight() {
        if emphasizesFirstLine, !hasMarkedText() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let full = NSRange(location: 0, length: (string as NSString).length)
            storage.setAttributes([.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ScratchpadStyle.secondary, .paragraphStyle: paragraph], range: full)
            let first = (string as NSString).lineRange(for: NSRange(location: 0, length: 0))
            if first.length > 0 {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: ScratchpadStyle.foreground], range: first)
            }
        }
        guard bounds.width > 0, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentRect.maxY)
        let newHeight = max(27, ceil(textHeight + 2 * textContainerInset.height))
        if height != newHeight {
            height = newHeight
            invalidateIntrinsicContentSize()
        }
    }
}
#endif
