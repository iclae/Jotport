#if os(macOS)
import AppKit
import Darwin
import JotportCore

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let searchPanel = ScratchpadSearch()
    var search: NSSearchField { searchPanel.field }
    var include: NSButton { searchPanel.includeArchived }
    private var searchReturnID: String?
    let windowPin = WindowPinButton()
    let searchButton = NSButton()
    let list = BlockListView()
    var blocks: [Block] = []
    var store: Store!
    var watcher: DispatchSourceFileSystemObject?
    var editingID: String?
    private var sessionInbox: SessionInbox!
    private var sessionLaunch: SessionLaunch!
    private let shortcutKey = "blockShortcuts"
    private let copyFeedback = NSVisualEffectView()
    private let copyFeedbackLabel = NSTextField(labelWithString: "已复制")
    private var copyFeedbackTimer: Timer?

    private var shortcuts: [BlockAction] {
        guard let stored = UserDefaults.standard.stringArray(forKey: shortcutKey) else { return BlockAction.defaults }
        return stored.compactMap(BlockAction.init(rawValue:))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jotport")
        let inboxDirectory = root.appendingPathComponent("inbox")
        do {
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try Store(path: root.appendingPathComponent("notes.sqlite").path)
            sessionInbox = SessionInbox(directory: inboxDirectory, store: store)
            sessionLaunch = SessionLaunch(
                root: root, store: store,
                blockForID: { [weak self] id in self?.blocks.first { $0.id == id } },
                publish: { [weak self] block in self?.publishBlock(block) },
                prompts: SessionLaunch.Prompts(
                    directory: { [weak self] request in self?.pickLaunchDirectory(request) },
                    retry: { [weak self] canReturn in self?.confirmSessionRetry(canReturn: canReturn) ?? .cancel },
                    alert: { [weak self] message in self?.alert(message) }
                )
            )
            blocks = try store.load()
            try sessionLaunch.markSessionsUnknownAfterRestart(&blocks)
        } catch { fatalError("无法打开本地数据库：\(error)") }
        buildUI(); reload()
        let fd = open(inboxDirectory.path, O_EVTONLY)
        if fd >= 0 {
            watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            watcher?.setEventHandler { [weak self] in self?.consume() }
            watcher?.setCancelHandler { close(fd) }; watcher?.resume()
        }
        consume()
        if blocks.isEmpty { newBlock() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let window else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func buildUI() {
        window = ScratchpadWindow(contentRect: NSRect(x: 160, y: 160, width: 444, height: 325), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Jotport"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ScratchpadStyle.background
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.setFrame(NSRect(x: 160, y: 160, width: 444, height: 325), display: false)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Jotport", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Jotport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editMenu.addItem(withTitle: "搜索笔记…", action: #selector(openSearch), keyEquivalent: "f").target = self
        editMenu.addItem(withTitle: "新建笔记", action: #selector(newBlock), keyEquivalent: "n").target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "撤销删除块", action: #selector(undoDelete), keyEquivalent: "").target = self
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        (window as? ScratchpadWindow)?.searchIsOpen = { [weak self] in self?.searchPanel.isOpen ?? false }
        (window as? ScratchpadWindow)?.closeSearch = { [weak self] in
            guard let self, (self.window as? ScratchpadWindow)?.routingCompositionEscape != true else { return false }
            return self.searchPanel.close()
        }
        searchPanel.changed = { [weak self] in self?.refresh() }
        searchPanel.closed = { [weak self] in
            guard let self else { return }
            self.searchButton.contentTintColor = ScratchpadStyle.secondary
            if let id = self.searchReturnID, self.list.focusBody(of: id) { return }
            self.list.focusFirstBody()
        }
        configureIcon(searchButton, symbol: "magnifyingglass", label: "搜索笔记（⌘F，再次点击关闭）", action: #selector(toggleSearch))
        configureIcon(windowPin, symbol: "pin", label: "窗口置顶", action: #selector(floatWindow(_:)))
        windowPin.synchronize(with: window)
        let options = iconButton("ellipsis", label: "选项与设置", action: #selector(showOptions(_:)))
        let add = iconButton("plus", label: "新建笔记（⌘N）", action: #selector(newBlock))
        add.contentTintColor = ScratchpadStyle.action
        let tools = NSStackView(views: [searchButton, windowPin, options, add])
        tools.spacing = 5
        let rail = TitleRail()
        let title = NSTextField(labelWithString: "Jotport")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = ScratchpadStyle.secondary
        for child in [title, tools] {
            child.translatesAutoresizingMaskIntoConstraints = false
            rail.addSubview(child)
        }
        NSLayoutConstraint.activate([
            rail.heightAnchor.constraint(equalToConstant: 42),
            title.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: rail.centerYAnchor),
            tools.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -8),
            tools.centerYAnchor.constraint(equalTo: rail.centerYAnchor)
        ])
        let searchInset = NSView()
        searchInset.translatesAutoresizingMaskIntoConstraints = false
        searchInset.addSubview(searchPanel.view)
        searchPanel.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchPanel.view.leadingAnchor.constraint(equalTo: searchInset.leadingAnchor, constant: 22),
            searchPanel.view.trailingAnchor.constraint(equalTo: searchInset.trailingAnchor, constant: -22),
            searchPanel.view.topAnchor.constraint(equalTo: searchInset.topAnchor, constant: 12),
            searchPanel.view.bottomAnchor.constraint(equalTo: searchInset.bottomAnchor, constant: -8)
        ])
        searchInset.isHidden = true
        searchPanel.visibilityChanged = { [weak searchInset] open in searchInset?.isHidden = !open }
        let top = NSStackView(views: [rail, searchInset])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 0
        rail.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        searchInset.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = ScratchpadStyle.divider
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let content = window.contentView!
        copyFeedback.material = .popover
        copyFeedback.blendingMode = .withinWindow
        copyFeedback.state = .active
        copyFeedback.wantsLayer = true
        copyFeedback.layer?.cornerRadius = 12
        copyFeedback.layer?.masksToBounds = true
        copyFeedback.isHidden = true
        copyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        copyFeedback.addSubview(copyFeedbackLabel)
        for view in [top, divider, scroll, copyFeedback] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 0),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: top.topAnchor, constant: 42),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.widthAnchor.constraint(equalTo: clip.widthAnchor),
            list.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            copyFeedback.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            copyFeedback.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            copyFeedbackLabel.leadingAnchor.constraint(equalTo: copyFeedback.leadingAnchor, constant: 12),
            copyFeedbackLabel.trailingAnchor.constraint(equalTo: copyFeedback.trailingAnchor, constant: -12),
            copyFeedbackLabel.topAnchor.constraint(equalTo: copyFeedback.topAnchor, constant: 6),
            copyFeedbackLabel.bottomAnchor.constraint(equalTo: copyFeedback.bottomAnchor, constant: -6)
        ])
        let compactHeight = list.heightAnchor.constraint(equalTo: clip.heightAnchor)
        compactHeight.priority = .defaultLow - 1
        compactHeight.isActive = true
        list.bodyChanged = { [weak self] in self?.updateBody($0, body: $1) }
        list.editingChanged = { [weak self] in self?.setEditing($0, active: $1) }
        list.performAction = { [weak self] in self?.perform($1, on: $0) }
        list.canDrop = { [weak self] in self?.canDrop($0, at: $1) == true }
        list.move = { [weak self] in self?.move($0, to: $1) == true }
        list.draggingChanged = { [weak self] dragging in
            if !dragging { self?.refresh() }
        }
    }

    func save(_ i: Int) {
        do { try store.save(blocks[i]) }
        catch { alert("保存失败：\(error.localizedDescription)") }
    }

    func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    func reload() {
        list.firstRowInset = searchPanel.isOpen ? 6 : 16
        let visible = blocks.filter { Reducer.matches($0, query: search.stringValue, archived: include.state == .on) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.order < $1.order }
        list.display(visible, shortcuts: shortcuts, canDrag: search.stringValue.isEmpty, actions: availableActions)
    }

    @objc func refresh() {
        promote()
        reload()
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = ScratchpadStyle.secondary
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        configureIcon(button, symbol: symbol, label: label, action: action)
        return button
    }
    @objc func toggleSearch() {
        if searchPanel.isOpen { searchPanel.close() } else { openSearch() }
    }
    @objc func openSearch() {
        if !searchPanel.isOpen { searchReturnID = editingID }
        searchButton.contentTintColor = ScratchpadStyle.action
        searchPanel.open(in: window)
    }
    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [("搜索笔记…", #selector(openSearch)), ("包含归档…", #selector(showArchive)), ("撤销删除块", #selector(undoDelete)), ("设置…", #selector(settings))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func showArchive() {
        openSearch()
        include.state = .on
        refresh()
    }

    private func setEditing(_ id: String, active: Bool) {
        if active {
            editingID = id
        } else if editingID == id {
            editingID = nil
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    private func updateBody(_ id: String, body: String) {
        guard let i = blocks.firstIndex(where: { $0.id == id }), blocks[i].body != body else { return }
        blocks[i].body = body
        blocks[i].revision += 1
        blocks[i].updated = Date()
        save(i)
    }

    @objc func newBlock() {
        searchPanel.close()
        var block = Block()
        block.order = (blocks.map(\.order).min() ?? 0) - 1
        blocks.append(block)
        save(blocks.count - 1)
        search.stringValue = ""
        reload()
        list.focusBody(of: block.id)
    }

    @discardableResult
    private func copy(_ value: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    private func showCopyFeedback() {
        copyFeedbackTimer?.invalidate()
        copyFeedback.isHidden = false
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: copyFeedbackLabel.stringValue,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copyFeedback.isHidden = true
        }
    }

    private func availableActions(_ block: Block) -> [BlockActionItem] {
        BlockAction.allCases.compactMap { action in
            switch action {
            case .chooseLaunch where block.association != nil, .chooseDirectory where block.association != nil:
                return nil
            case .returnToSession where block.run == nil:
                return nil
            case .clearBinding where block.association == nil:
                return nil
            case .pin where block.pinned:
                return BlockActionItem(action: action, title: "取消置顶")
            case .archive where block.archived:
                return BlockActionItem(action: action, title: "恢复归档")
            case .resume:
                return BlockActionItem(action: action, title: action.title, enabled: SessionLaunch.canResume(block))
            case .copyID:
                return BlockActionItem(action: action, title: action.title, enabled: block.association?.sessionID != nil)
            case .toggleRecap:
                guard !block.recap.isEmpty else { return nil }
                let title = block.recapHidden == true ? action.title : "隐藏最近回复"
                return BlockActionItem(action: action, title: title)
            default:
                return BlockActionItem(action: action, title: action.title)
            }
        }
    }

    private func perform(_ action: BlockAction, on id: String) {
        guard let i = blocks.firstIndex(where: { $0.id == id && !$0.deleted }) else { return }
        switch action {
        case .returnToSession:
            consume()
            sessionLaunch.perform(.returnToSession, on: id)
            return
        case .start:
            consume()
            sessionLaunch.perform(.startOrReturn, on: id)
            return
        case .chooseLaunch:
            chooseLaunch(i)
            return
        case .chooseDirectory:
            sessionLaunch.perform(.changeDirectory, on: id)
            return
        case .clearBinding:
            guard blocks[i].association != nil else { return }
            var updated = blocks[i]
            updated.clearBinding()
            do {
                try store.save(updated)
                publishBlock(updated)
            } catch {
                alert("保存失败：\(error.localizedDescription)")
            }
            return
        case .copyBody:
            if copy(blocks[i].body) { showCopyFeedback() }
            return
        case .resume:
            sessionLaunch.perform(.resume, on: id)
            return
        case .copyID:
            if let sessionID = blocks[i].association?.sessionID { copy(sessionID) }
            return
        case .pin:
            blocks[i].pinned.toggle()
        case .archive:
            blocks[i].archived.toggle()
        case .remove:
            blocks[i].deleted = true
            blocks[i].updated = Date()
        case .toggleRecap:
            blocks[i].recapHidden = blocks[i].recapHidden != true
        }
        save(i)
        reload()
    }

    @objc func undoDelete() {
        guard let i = blocks.indices.filter({ blocks[$0].deleted }).max(by: { blocks[$0].updated < blocks[$1].updated }) else { return }
        blocks[i].deleted = false
        save(i)
        reload()
    }

    @objc func floatWindow(_ sender: NSButton) {
        windowPin.toggle(window: window)
    }

    private func canDrop(_ id: String, at target: BlockListView.Drop) -> Bool {
        guard search.stringValue.isEmpty,
              let source = blocks.first(where: { $0.id == id && !$0.deleted }),
              let anchor = blocks.first(where: { $0.id == target.anchorID && !$0.deleted }) else { return false }
        return source.pinned == anchor.pinned
    }

    private func move(_ id: String, to target: BlockListView.Drop) -> Bool {
        guard canDrop(id, at: target), let source = blocks.firstIndex(where: { $0.id == id }) else { return false }
        if id == target.anchorID { return true }
        let current = blocks.indices.filter { !blocks[$0].deleted && blocks[$0].pinned == blocks[source].pinned }
            .sorted { blocks[$0].order < blocks[$1].order }
        var order = current.filter { $0 != source }
        let anchor = order.firstIndex { blocks[$0].id == target.anchorID }!
        switch target {
        case .before: order.insert(source, at: anchor)
        case .after: order.insert(source, at: anchor + 1)
        }
        guard order != current else { return true }
        let changes = order.enumerated().compactMap { rank, index -> (Int, Block)? in
            var block = blocks[index]
            guard block.order != Double(rank) else { return nil }
            block.order = Double(rank)
            return (index, block)
        }
        do {
            try store.save(changes.map { $0.1 })
            for (index, block) in changes { blocks[index] = block }
            reload()
            return true
        } catch {
            alert("保存顺序失败：\(error.localizedDescription)")
            return false
        }
    }

    func consume() {
        let error = sessionInbox.consume(into: &blocks)
        refresh()
        if let error { alert("事件保存失败：\(error.localizedDescription)") }
    }
    func promote() {
        guard editingID == nil, !list.dragging, search.stringValue.isEmpty,
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        let pending = blocks.filter { $0.attention != nil && $0.attention != $0.attentionPromoted }.sorted { ($0.attentionTime ?? "") < ($1.attentionTime ?? "") }
        for b in pending {
            guard let i = blocks.firstIndex(where: { $0.id == b.id }) else { continue }
            if !b.pinned, !b.archived, !b.deleted { blocks[i].order = (blocks.map(\.order).min() ?? 0) - 1 }
            blocks[i].attentionPromoted = b.attention; save(i)
        }
    }

    private func launchPicker(_ values: [String], selected: String, label: String) -> NSPopUpButton {
        let picker = NSPopUpButton()
        picker.addItems(withTitles: values)
        picker.selectItem(withTitle: selected)
        picker.setAccessibilityLabel(label)
        return picker
    }

    private func launchPickers() -> (agent: NSPopUpButton, terminal: NSPopUpButton) {
        let saved = LaunchOptions.saved()
        return (launchPicker(LaunchOptions.Agent.allCases.map(\.rawValue), selected: saved.agent.rawValue, label: "Agent"),
                launchPicker(LaunchOptions.Terminal.allCases.map(\.rawValue), selected: saved.terminal.rawValue, label: "终端"))
    }

    private func pickerRow(_ agent: NSPopUpButton, _ terminal: NSPopUpButton) -> NSStackView {
        NSStackView(views: [NSTextField(labelWithString: "Agent"), agent, NSTextField(labelWithString: "终端"), terminal])
    }

    private func chooseLaunch(_ i: Int) {
        guard blocks[i].association == nil else { return }
        let blockID = blocks[i].id
        let (agent, terminal) = launchPickers()
        let row = pickerRow(agent, terminal)
        row.frame.size = row.fittingSize
        let alert = NSAlert()
        alert.messageText = "选择 agent 和终端"
        alert.informativeText = "所选设置只用于这次启动。"
        alert.accessoryView = row
        alert.addButton(withTitle: "启动")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let saved = LaunchOptions.saved()
        let options = LaunchOptions(
            agent: agent.titleOfSelectedItem.flatMap(LaunchOptions.Agent.init(rawValue:)) ?? saved.agent,
            terminal: terminal.titleOfSelectedItem.flatMap(LaunchOptions.Terminal.init(rawValue:)) ?? saved.terminal
        )
        sessionLaunch.perform(.startNew(options), on: blockID)
    }

    @objc func settings() {
        let alert = NSAlert()
        alert.messageText = "Jotport 设置"
        let (agent, terminal) = launchPickers()
        let names = ["WezTermApp", "GhosttyApp", "codexPath", "piPath", "arguments"]
        let labels = ["WezTerm 应用路径", "Ghostty 应用路径", "Codex 可执行文件", "pi 可执行文件", "参数（JSON 字符串数组）"]
        let paths = LaunchOptions.defaultAgentPaths()
        let defaults = [LaunchOptions.Terminal.wezTerm.defaultPath, LaunchOptions.Terminal.ghostty.defaultPath,
                        paths.codex, paths.pi, "[]"]
        let stack = NSStackView(views: [pickerRow(agent, terminal)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        var fields: [NSTextField] = []
        for (index, key) in names.enumerated() {
            let field = NSTextField(string: UserDefaults.standard.string(forKey: key) ?? defaults[index])
            field.setAccessibilityLabel(labels[index])
            field.widthAnchor.constraint(equalToConstant: 430).isActive = true
            stack.addArrangedSubview(NSTextField(labelWithString: labels[index]))
            stack.addArrangedSubview(field)
            fields.append(field)
        }

        let shortcutSettings = ShortcutSettingsView(actions: shortcuts)
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 470, height: 350))
        for (title, view) in [("终端与 agent", stack), ("块快捷操作", shortcutSettings)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let container = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14)
            ])
            item.view = container
            tabs.addTabViewItem(item)
        }
        alert.accessoryView = tabs
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let preferences = UserDefaults.standard
            for (key, field) in zip(names, fields) { preferences.set(field.stringValue, forKey: key) }
            preferences.set(agent.titleOfSelectedItem, forKey: "agent")
            preferences.set(terminal.titleOfSelectedItem, forKey: "terminal")
            preferences.set(shortcutSettings.actions.map(\.rawValue), forKey: shortcutKey)
            reload()
        }
    }

    private func publishBlock(_ block: Block) {
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index] = block
        reload()
    }

    private func pickLaunchDirectory(_ request: SessionLaunch.DirectoryPrompt) -> String? {
        let paths = RecentLaunchDirectories().paths
        if !paths.isEmpty {
            let choice = NSAlert()
            choice.messageText = "选择启动路径"
            if case let .unavailable(path) = request {
                choice.informativeText = "原启动路径已不可用：\(path)\n选择最近使用的目录，或选择其他目录。"
            } else {
                choice.informativeText = "最近使用的目录"
            }
            let recent = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
            recent.setAccessibilityLabel("最近使用的启动目录")
            for path in paths {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                recent.addItem(withTitle: "\(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent) — \(url.deletingLastPathComponent().path)")
                recent.lastItem?.toolTip = path
            }
            choice.accessoryView = recent
            choice.addButton(withTitle: "使用所选目录")
            choice.addButton(withTitle: "选择其他目录…")
            choice.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            switch choice.runModal() {
            case .alertFirstButtonReturn:
                let path = paths[recent.indexOfSelectedItem]
                if RecentLaunchDirectories.isAvailable(path) { return path }
                alert("所选目录已不可用，请选择其他目录。")
            case .alertSecondButtonReturn:
                break
            default:
                return nil
            }
        }
        let panel = NSOpenPanel()
        panel.title = "选择启动路径"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        switch request {
        case .initial:
            break
        case let .existing(path):
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        case let .unavailable(path):
            panel.message = "原启动路径已不可用，请选择另一个文件夹：\(path)"
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func confirmSessionRetry(canReturn: Bool) -> SessionLaunch.RetryChoice {
        let confirmation = NSAlert()
        confirmation.messageText = "上一次启动未确认"
        confirmation.informativeText = "先在原终端确认这个块没有对应的会话，再重试启动。"
        confirmation.addButton(withTitle: "取消")
        confirmation.addButton(withTitle: "确认重试")
        if canReturn { confirmation.addButton(withTitle: "返回原终端") }
        switch confirmation.runModal() {
        case .alertSecondButtonReturn:
            return .retry
        case .alertThirdButtonReturn:
            return .returnToTerminal
        default:
            return .cancel
        }
    }
}
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == CodexBridge.argument {
    CodexBridge.run(executable: arguments[2], expectedSessionID: arguments.dropFirst(3).first)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
print("Jotport UI requires macOS 12 or newer. Run swift test for portable core validation.")
#endif
