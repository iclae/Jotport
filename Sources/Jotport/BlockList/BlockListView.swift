#if os(macOS)
import AppKit
import JotportCore

private let blockDragType = NSPasteboard.PasteboardType("com.iclae.jotport.block")

final class BlockListView: NSView {
    enum Drop {
        case before(String)
        case after(String)

        var anchorID: String {
            switch self {
            case .before(let id), .after(let id): return id
            }
        }
    }

    var firstRowInset: CGFloat = 16
    var bodyChanged: ((String, String) -> Void)?
    var editingChanged: ((String, Bool) -> Void)?
    var performAction: ((String, BlockAction) -> Void)?
    var draggingChanged: ((Bool) -> Void)?
    var canDrop: ((String, Drop) -> Bool)?
    var move: ((String, Drop) -> Bool)?
    private(set) var dragging = false

    private let stack = NSStackView()
    private let dropLine = NSBox()
    private var dropLinePosition: NSLayoutConstraint!
    private var rows: [String: BlockRowView] = [:]
    private var visibleIDs: [String] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        dropLine.boxType = .custom
        dropLine.borderWidth = 0
        dropLine.fillColor = .controlAccentColor
        dropLine.isHidden = true
        dropLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropLine)
        dropLinePosition = dropLine.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            dropLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dropLine.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            dropLine.heightAnchor.constraint(equalToConstant: 2),
            dropLinePosition
        ])
        registerForDraggedTypes([blockDragType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(
        _ blocks: [Block],
        shortcuts: [BlockAction],
        canDrag: Bool,
        actions: (Block) -> [BlockActionItem]
    ) {
        let ids = blocks.map(\.id)
        if ids != visibleIDs {
            for id in Set(visibleIDs).subtracting(ids) {
                rows.removeValue(forKey: id)?.removeFromSuperview()
            }
            for (index, block) in blocks.enumerated() {
                let row = rows[block.id] ?? addRow(block, at: index)
                if stack.arrangedSubviews[index] !== row {
                    stack.removeArrangedSubview(row)
                    stack.insertArrangedSubview(row, at: index)
                }
            }
            visibleIDs = ids
        }

        for (index, block) in blocks.enumerated() {
            rows[block.id]?.configureSpacing(top: index == 0 ? firstRowInset : 6, last: index == blocks.count - 1)
            rows[block.id]?.update(block, actions: actions(block), shortcuts: shortcuts, canDrag: canDrag, dragging: dragging)
        }
    }

    func focusFirstBody() {
        if let id = visibleIDs.first { focusBody(of: id) }
    }

    @discardableResult func focusBody(of id: String) -> Bool {
        layoutSubtreeIfNeeded()
        guard let row = rows[id] else { return false }
        scrollToVisible(convert(row.bounds, from: row))
        row.focusBody()
        return true
    }

    private func addRow(_ block: Block, at index: Int) -> BlockRowView {
        let id = block.id
        let handle = BlockDragHandle(id: id)
        handle.draggingChanged = { [weak self] in self?.setDragging($0) }
        let row = BlockRowView(block: block, dragHandle: handle)
        row.bodyChanged = { [weak self] in self?.bodyChanged?(id, $0) }
        row.editingChanged = { [weak self] in self?.editingChanged?(id, $0) }
        row.performAction = { [weak self] in self?.performAction?(id, $0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(row, at: index)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rows[id] = row
        return row
    }

    private func setDragging(_ active: Bool) {
        dragging = active
        for row in rows.values { row.setDragging(active) }
        if !active { dropLine.isHidden = true }
        draggingChanged?(active)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        scrollDuringDrag(at: point)
        guard let (_, _, position) = proposedDrop(sender) else {
            dropLine.isHidden = true
            return []
        }
        dropLinePosition.constant = max(0, position - 1)
        dropLine.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLine.isHidden = true
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropLine.isHidden = true
        guard let (id, target, _) = proposedDrop(sender) else { return false }
        return move?(id, target) ?? false
    }

    private func proposedDrop(_ sender: NSDraggingInfo) -> (String, Drop, CGFloat)? {
        guard dragging, let id = sender.draggingPasteboard.string(forType: blockDragType) else { return nil }
        let y = convert(sender.draggingLocation, from: nil).y
        let views = stack.arrangedSubviews.compactMap { $0 as? BlockRowView }
        let index = views.firstIndex { convert($0.bounds, from: $0).midY > y } ?? views.count
        if index < views.count {
            let next = views[index]
            let target = Drop.before(next.id)
            if canDrop?(id, target) == true { return (id, target, convert(next.bounds, from: next).minY) }
        }
        if index > 0 {
            let previous = views[index - 1]
            let target = Drop.after(previous.id)
            if canDrop?(id, target) == true { return (id, target, convert(previous.bounds, from: previous).maxY) }
        }
        return nil
    }

    private func scrollDuringDrag(at point: NSPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let visible = scroll.documentVisibleRect
        let margin: CGFloat = 20
        let step: CGFloat = 12
        let offset: CGFloat
        if point.y < visible.minY + margin {
            offset = -step
        } else if point.y > visible.maxY - margin {
            offset = step
        } else {
            return
        }
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: offset)).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

final class BlockDragHandle: NSImageView, NSDraggingSource {
    var draggingChanged: ((Bool) -> Void)?
    private let id: String
    private var mouseDownAt: NSPoint?

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        let grip = NSImage(size: NSSize(width: 10, height: 15), flipped: false) { _ in
            NSColor.black.setFill()
            for x in [CGFloat(1), 6] {
                for y in [CGFloat(1), 6, 11] {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 3, height: 3)).fill()
                }
            }
            return true
        }
        grip.isTemplate = true
        image = grip
        imageScaling = .scaleNone
        contentTintColor = .secondaryLabelColor
        toolTip = "拖动块"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt, let image,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownAt = nil
        let writer = NSPasteboardItem()
        writer.setString(id, forType: blockDragType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        draggingChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingChanged?(false)
    }
}
#endif
