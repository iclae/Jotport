#if os(macOS)
import AppKit

enum BlockAction: String, CaseIterable {
    case returnToSession, start, chooseLaunch, chooseDirectory, clearBinding, copyBody, pin, archive, remove, resume, copyID, toggleRecap

    static let defaults: [Self] = [.start, .copyBody, .pin]
    static let shortcutOptions = allCases.filter { $0 != .returnToSession && $0 != .chooseDirectory && $0 != .clearBinding }

    var title: String {
        switch self {
        case .returnToSession: return "返回绑定会话"
        case .start: return "启动 / 返回"
        case .chooseLaunch: return "选择 agent 和终端…"
        case .chooseDirectory: return "修改启动路径…"
        case .clearBinding: return "清理绑定"
        case .copyBody: return "复制"
        case .pin: return "置顶"
        case .archive: return "归档"
        case .remove: return "删除"
        case .resume: return "按原 ID 恢复"
        case .copyID: return "复制会话 ID"
        case .toggleRecap: return "查看最近回复"
        }
    }

    var symbol: String {
        switch self {
        case .returnToSession: return "arrow.up.forward.app"
        case .start: return "terminal"
        case .chooseLaunch: return "slider.horizontal.3"
        case .chooseDirectory: return "folder"
        case .clearBinding: return "link"
        case .copyBody: return "doc.on.doc"
        case .pin: return "pin"
        case .archive: return "archivebox"
        case .remove: return "trash"
        case .resume: return "arrow.clockwise"
        case .copyID: return "number"
        case .toggleRecap: return "text.alignleft"
        }
    }
}

struct BlockActionItem: Equatable {
    var action: BlockAction
    var title: String
    var enabled: Bool = true
}

final class ShortcutSettingsView: NSStackView {
    private(set) var actions: [BlockAction]
    private let choices = NSPopUpButton()
    private let selected = NSStackView()

    init(actions: [BlockAction]) {
        self.actions = actions
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        choices.setAccessibilityLabel("添加块快捷操作")
        choices.target = self
        choices.action = #selector(addShortcut)
        selected.orientation = .vertical
        selected.alignment = .leading
        selected.spacing = 3
        addArrangedSubview(choices)
        addArrangedSubview(selected)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func reload() {
        choices.removeAllItems()
        choices.addItem(withTitle: "添加快捷操作…")
        choices.item(at: 0)?.isEnabled = false
        for action in BlockAction.shortcutOptions where !actions.contains(action) {
            choices.addItem(withTitle: action.title)
            choices.lastItem?.representedObject = action.rawValue
        }
        choices.autoenablesItems = false
        choices.isEnabled = choices.numberOfItems > 1
        for row in selected.arrangedSubviews {
            row.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let label = NSTextField(labelWithString: action.title)
            label.widthAnchor.constraint(equalToConstant: 165).isActive = true
            let up = editButton("arrow.up", "上移", index, #selector(moveShortcutUp(_:)))
            let down = editButton("arrow.down", "下移", index, #selector(moveShortcutDown(_:)))
            let remove = editButton("minus.circle", "移除", index, #selector(removeShortcut(_:)))
            up.isEnabled = index > 0
            down.isEnabled = index + 1 < actions.count
            let row = NSStackView(views: [label, up, down, remove])
            selected.addArrangedSubview(row)
        }
    }

    private func editButton(_ symbol: String, _ title: String, _ index: Int, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
        let button = NSButton(image: image, target: self, action: action)
        button.tag = index
        button.toolTip = title
        button.setAccessibilityLabel(title + "「" + actions[index].title + "」")
        return button
    }

    @objc private func addShortcut() {
        guard let value = choices.selectedItem?.representedObject as? String,
              let action = BlockAction(rawValue: value) else { return }
        actions.append(action)
        reload()
    }

    @objc private func moveShortcutUp(_ sender: NSButton) {
        actions.swapAt(sender.tag, sender.tag - 1)
        reload()
    }

    @objc private func moveShortcutDown(_ sender: NSButton) {
        actions.swapAt(sender.tag, sender.tag + 1)
        reload()
    }

    @objc private func removeShortcut(_ sender: NSButton) {
        actions.remove(at: sender.tag)
        reload()
    }
}
#endif
