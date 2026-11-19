#if os(macOS)
import AppKit
import Carbon
import JotportCore

final class App: NSObject, NSApplicationDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    let search = NSSearchField()
    let include = NSButton(checkboxWithTitle: "包含归档", target: nil, action: nil)
    let list = BlockListView()
    var blocks: [Block] = []
    var store: Store!
    var root: URL!
    var watcher: DispatchSourceFileSystemObject?
    var editingID: String?
    private var sessionInbox: SessionInbox!
    private var terminalLaunchPaths: [String: String] = [:]
    private let shortcutKey = "blockShortcuts"
    private let copyFeedback = NSVisualEffectView()
    private let copyFeedbackLabel = NSTextField(labelWithString: "已复制")
    private var copyFeedbackTimer: Timer?

    struct LaunchOptions {
        static let agents = ["codex", "pi"]
        static let terminals = ["WezTerm", "Ghostty"]

        var agent: String
        var terminal: String

        static var saved: Self {
            let defaults = UserDefaults.standard
            return Self(agent: defaults.string(forKey: "agent") ?? "codex",
                        terminal: defaults.string(forKey: "terminal") ?? "WezTerm")
        }
    }

    private var shortcuts: [BlockAction] {
        guard let stored = UserDefaults.standard.stringArray(forKey: shortcutKey) else { return BlockAction.defaults }
        return stored.compactMap(BlockAction.init(rawValue:))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jotport")
        let inboxDirectory = root.appendingPathComponent("inbox")
        do {
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try Store(path: root.appendingPathComponent("notes.sqlite").path)
            sessionInbox = SessionInbox(directory: inboxDirectory, store: store)
            blocks = try store.load()
            for i in blocks.indices where blocks[i].run != nil && blocks[i].run?.status != "已退出" { blocks[i].run?.status = "状态未知：需核对终端"; try store.save(blocks[i]) }
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
        window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Jotport · 测试版"
        window.contentMinSize = NSSize(width: 490, height: 240)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Jotport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "撤销删除块", action: #selector(undoDelete), keyEquivalent: "").target = self
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        search.placeholderString = "搜索正文、概况、会话 ID"
        search.delegate = self
        search.target = self
        search.action = #selector(refresh)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        include.target = self
        include.action = #selector(refresh)
        let windowPin = NSButton(checkboxWithTitle: "窗口置顶", target: self, action: #selector(floatWindow(_:)))
        windowPin.state = .off
        let top = NSStackView(views: [button("＋ 新建", #selector(newBlock)), search, include, windowPin, button("设置", #selector(settings))])
        top.spacing = 12

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        let divider = NSBox()
        divider.boxType = .separator
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
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
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
        let visible = blocks.filter { Reducer.matches($0, query: search.stringValue, archived: include.state == .on) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.order < $1.order }
        list.display(visible, shortcuts: shortcuts, canDrag: search.stringValue.isEmpty, actions: availableActions)
    }

    @objc func refresh() {
        promote()
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

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
            case .clearBinding where block.association == nil:
                return nil
            case .pin where block.pinned:
                return BlockActionItem(action: action, title: "取消置顶")
            case .archive where block.archived:
                return BlockActionItem(action: action, title: "恢复归档")
            case .resume:
                return BlockActionItem(action: action, title: action.title, enabled: block.association?.sessionID != nil && block.run?.status == "已退出")
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
        case .start:
            start(i)
            return
        case .chooseLaunch:
            chooseLaunch(i)
            return
        case .chooseDirectory:
            if blocks[i].association == nil, let path = pickLaunchDirectory(blocks[i].launchDirectory) {
                saveLaunchDirectory(path, at: i)
            }
            return
        case .clearBinding:
            guard blocks[i].association != nil else { return }
            var updated = blocks[i]
            updated.clearBinding()
            saveBlockChange(updated, at: i)
            return
        case .copyBody:
            if copy(blocks[i].body) { showCopyFeedback() }
            return
        case .resume:
            resume(i)
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
        window.level = sender.state == .on ? .floating : .normal
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
        let saved = LaunchOptions.saved
        return (launchPicker(LaunchOptions.agents, selected: saved.agent, label: "Agent"),
                launchPicker(LaunchOptions.terminals, selected: saved.terminal, label: "终端"))
    }

    private func pickerRow(_ agent: NSPopUpButton, _ terminal: NSPopUpButton) -> NSStackView {
        NSStackView(views: [NSTextField(labelWithString: "Agent"), agent, NSTextField(labelWithString: "终端"), terminal])
    }

    private func chooseLaunch(_ i: Int) {
        guard blocks[i].association == nil else { return }
        let (agent, terminal) = launchPickers()
        let row = pickerRow(agent, terminal)
        row.frame.size = row.fittingSize
        let alert = NSAlert()
        alert.messageText = "选择 agent 和终端"
        alert.informativeText = "所选设置只用于这次启动。"
        alert.accessoryView = row
        alert.addButton(withTitle: "启动")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, blocks[i].association == nil, !blocks[i].deleted {
            launch(i, restoring: false, options: LaunchOptions(agent: agent.titleOfSelectedItem ?? LaunchOptions.saved.agent, terminal: terminal.titleOfSelectedItem ?? LaunchOptions.saved.terminal))
        }
    }

    @objc func settings() {
        let alert = NSAlert()
        alert.messageText = "Jotport 设置"
        let (agent, terminal) = launchPickers()
        let names = ["WezTermApp", "GhosttyApp", "codexPath", "piPath", "arguments"]
        let labels = ["WezTerm 应用路径", "Ghostty 应用路径", "Codex 可执行文件", "pi 可执行文件", "参数（JSON 字符串数组）"]
        let searchPath = agentSearchPath()
        let defaults = ["/Applications/WezTerm.app", "/Applications/Ghostty.app", defaultAgentPath("codex", searchPath: searchPath), defaultAgentPath("pi", searchPath: searchPath), "[]"]
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

    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func defaultAgentPath(_ name: String, searchPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let npmGlobal = name == "codex" ? [home.appendingPathComponent(".npm-global/bin/codex").path] : []
        let system = "/usr/local/bin/\(name)"
        let local = home.appendingPathComponent(".local/bin/\(name)").path
        let candidates = npmGlobal + [system, local] + searchPath.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? system
    }
    func agentSearchPath() -> String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let shell = getpwuid(getuid())?.pointee.pw_shell,
              let output = try? capture(String(cString: shell), ["-lc", "/usr/bin/printenv PATH"]),
              let path = output.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") else { return inherited }
        return String(path)
    }
    func capture(_ path: String, _ args: [String], environment: [String: String]? = nil) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.environment = environment
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        // Bound diagnostics; never used as an input-readiness signal.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "探测失败"]) }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func start(_ i: Int) {
        consume()
        guard let run = blocks[i].run else { launch(i, restoring: false); return }
        if run.status == "启动中" { return }
        let original = run.terminal.flatMap(runningTerminal)
        if canRetry(i, runID: run.id) {
            let confirmation = NSAlert()
            confirmation.messageText = "上一次启动未确认"
            confirmation.informativeText = "先在原终端确认这个块没有对应的会话，再重试启动。"
            confirmation.addButton(withTitle: "取消")
            confirmation.addButton(withTitle: "确认重试")
            if original != nil { confirmation.addButton(withTitle: "返回原终端") }
            let choice = confirmation.runModal()
            if choice == .alertSecondButtonReturn, canRetry(i, runID: run.id) {
                launch(i, restoring: false, retrying: run.id)
            } else if choice == .alertThirdButtonReturn, let original {
                activateTerminal(original)
            }
            return
        }
        guard let original else { alert("状态未知，启动请求已保留。请核对终端。确认原运行退出后可按原 ID 恢复。"); return }
        activateTerminal(original)
    }
    func runningTerminal(_ ref: TerminalRef) -> NSRunningApplication? {
        guard let pid = ref.processID, let launchedAt = ref.launchedAt,
              let application = NSRunningApplication(processIdentifier: pid),
              application.bundleURL?.resolvingSymlinksInPath().path == ref.path,
              application.launchDate == launchedAt else { return nil }
        return application
    }
    func activateTerminal(_ application: NSRunningApplication) {
        application.activate(options: [.activateIgnoringOtherApps])
    }
    func canRetry(_ i: Int, runID: String) -> Bool {
        blocks[i].run?.id == runID && blocks[i].association?.sessionID == nil &&
            !FileManager.default.fileExists(atPath: launchMarker(runID).path)
    }
    func launchMarker(_ runID: String) -> URL {
        root.appendingPathComponent("runs/\(runID)/started")
    }
    func resume(_ i: Int) {
        guard blocks[i].association?.sessionID != nil else { alert("尚未收到会话 ID，无法恢复原会话。"); return }
        guard blocks[i].run?.status == "已退出" else { alert("尚未确认对应运行退出；为防止重复运行，暂不恢复。"); return }
        launch(i, restoring: true)
    }

    @discardableResult
    private func saveBlockChange(_ block: Block, at i: Int) -> Bool {
        do {
            try store.save(block)
            blocks[i] = block
            reload()
            return true
        } catch {
            alert("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func pickLaunchDirectory(_ currentPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择启动路径"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let path = currentPath {
            if isDirectory(path) {
                panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                panel.message = "原启动路径已不可用，请选择另一个文件夹：\(path)"
            }
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @discardableResult
    private func saveLaunchDirectory(_ path: String, at i: Int) -> Bool {
        guard !blocks[i].deleted, blocks[i].association == nil else { return false }
        var updated = blocks[i]
        updated.launchDirectory = path
        return saveBlockChange(updated, at: i)
    }

    func launch(_ i: Int, restoring: Bool, options: LaunchOptions = .saved, retrying runID: String? = nil) {
        let cwd: String
        if restoring {
            guard let association = blocks[i].association else { return }
            cwd = association.directory
        } else {
            let savedPath = blocks[i].launchDirectory ?? blocks[i].association?.directory
            if let savedPath, isDirectory(savedPath) {
                cwd = savedPath
            } else {
                guard let path = pickLaunchDirectory(savedPath) else { return }
                if let runID {
                    guard canRetry(i, runID: runID) else { return }
                } else {
                    guard saveLaunchDirectory(path, at: i) else { return }
                }
                cwd = path
            }
        }
        let defaults = UserDefaults.standard
        let name = restoring ? blocks[i].association!.agent : options.agent
        let term = options.terminal
        let terminalURL = URL(fileURLWithPath: defaults.string(forKey: term + "App") ?? "/Applications/\(term).app").resolvingSymlinksInPath()
        let path = terminalURL.path
        guard !terminalLaunchPaths.values.contains(path) else {
            alert("\(term) 正在启动另一个会话。请稍后再试。"); return
        }
        do {
            guard let bundle = Bundle(url: terminalURL), let identity = bundle.bundleIdentifier, let terminalCLI = bundle.executableURL else {
                alert("找不到 \(term) 安装包。请在设置中检查路径 \(path)"); return
            }
            guard isDirectory(cwd) else {
                alert("工作目录不可用：\(cwd)"); return
            }
            let searchPath = agentSearchPath()
            let cli = defaults.string(forKey: name + "Path") ?? defaultAgentPath(name, searchPath: searchPath)
            guard FileManager.default.isExecutableFile(atPath: cli) else {
                alert("无法执行 \(name)。请在设置中检查路径 \(cli)"); return
            }
            var agentEnvironment = ProcessInfo.processInfo.environment
            agentEnvironment["PATH"] = searchPath
            // 使用登录 shell 的 PATH 后，Volta 需要重新解析 Node 版本。
            agentEnvironment.removeValue(forKey: "_VOLTA_TOOL_RECURSION")
            let version = try capture(cli, ["--version"], environment: agentEnvironment)
            let help = try capture(terminalCLI.path, ["--help"])
            let dictionary = (try? capture("/usr/bin/sdef", [path])) ?? "无可用脚本字典；不使用未经验证的 AppleScript 接口"
            let diagnostics = "path=\(path)\nidentity=\(identity)\nappVersion=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")\nbuild=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")\nagentPath=\(cli)\nagent=\(version)\nhelp=\(help)\nsdef=\(dictionary)"
            try diagnostics.write(to: root.appendingPathComponent("last-probe.txt"), atomically: true, encoding: .utf8)
            guard let argsData = (defaults.string(forKey: "arguments") ?? "[]").data(using: .utf8), let extra = try? JSONDecoder().decode([String].self, from: argsData) else { alert("参数必须是 JSON 字符串数组"); return }
            // Arbitrary positional prompts could submit content. This preview accepts no custom agent args.
            guard extra.isEmpty else { alert("测试版暂不执行自定义参数，以避免位置参数被 CLI 当作初始 prompt 自动发送。"); return }
            var run = Run(snapshot: restoring ? "" : blocks[i].body)
            run.terminal = TerminalRef(path: path, identity: identity, version: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")")
            let dir = root.appendingPathComponent("runs/\(run.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try run.snapshot.write(to: dir.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
            var argv = [cli]
            if restoring, let id = blocks[i].association?.sessionID { argv += name == "codex" ? ["resume", id] : ["--session", id] }
            if name == "pi", let extensionURL = Bundle.main.url(forResource: "jotport", withExtension: "ts") { argv += ["--extension", extensionURL.path] }
            var command = "exec \(argv.map(quote).joined(separator: " "))"
            if name == "codex", let helper = Bundle.main.executableURL,
               let serverHelp = try? capture(cli, ["app-server", "--help"], environment: agentEnvironment),
               serverHelp.contains("--ws-token-file"),
               let cliHelp = try? capture(cli, ["--help"], environment: agentEnvironment),
               cliHelp.contains("--remote-auth-token-env") {
                command = CodexBridge.launchCommand(helper: helper, cli: cli,
                                                    sessionID: restoring ? blocks[i].association?.sessionID : nil,
                                                    quote: quote)
            }
            let environment = ["JOTPORT_RUN": run.id, "JOTPORT_INBOX": root.appendingPathComponent("inbox").path, "JOTPORT_SNAPSHOT": restoring ? "" : dir.appendingPathComponent("snapshot.txt").path, "JOTPORT_RUN_DIR": dir.path]
            let exports = environment.map { "export \($0.key)=\(quote($0.value))" }.joined(separator: "\n")
            let script = """
            #!/bin/sh
            cd \(quote(cwd)) || exit 1
            export PATH=\(quote(searchPath))
            unset _VOLTA_TOOL_RECURSION
            \(exports)
            : > \(quote(launchMarker(run.id).path)) || exit 1
            \(command)
            """
            let scriptURL = dir.appendingPathComponent("launch.sh"); try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            var candidate = blocks[i]
            if !restoring {
                if let runID {
                    guard canRetry(i, runID: runID) else { return }
                    candidate.clearBinding()
                }
                candidate.launchDirectory = cwd
                candidate.association = Association(agent: name, directory: cwd)
            }
            candidate.run = run
            try store.save(candidate)
            blocks[i] = candidate
            reload()

            terminalLaunchPaths[run.id] = path
            openTerminal(term, at: terminalURL, identity: identity, executable: terminalCLI, script: scriptURL, cwd: cwd, runID: run.id)
        } catch {
            alert("启动准备失败。\(error.localizedDescription)")
        }
    }
    func openTerminal(_ name: String, at url: URL, identity: String, executable: URL, script: URL, cwd: String, runID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identity)
        let existing = running.filter { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == url.path }
        if let application = existing.first(where: \.isActive) ?? existing.first {
            DispatchQueue.global().async { [self] in
                do {
                    if name == "WezTerm" {
                        try openWezTermTab(application: application, executable: executable, script: script, cwd: cwd)
                    } else {
                        try openGhosttyTab(application: application, script: script, cwd: cwd)
                    }
                    DispatchQueue.main.async {
                        if self.blocks.contains(where: { $0.run?.id == runID }) {
                            self.activateTerminal(application)
                        }
                        self.confirmLaunch(runID, application: application, deadline: ProcessInfo.processInfo.systemUptime + 10)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.finishLaunch(runID, status: "无法在 \(name) 打开标签页。\(error.localizedDescription)")
                    }
                }
            }
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = !running.isEmpty
        config.arguments = (name == "WezTerm" ? ["start", "--always-new-process", "--cwd", cwd, "--"] : ["-e"]) + ["/bin/sh", script.path]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let application {
                    self.confirmLaunch(runID, application: application, deadline: ProcessInfo.processInfo.systemUptime + 10)
                } else {
                    self.finishLaunch(runID, status: "打开 \(name) 失败。\(error?.localizedDescription ?? "系统未返回启动结果。")")
                }
            }
        }
    }
    func openWezTermTab(application: NSRunningApplication, executable: URL, script: URL, cwd: String) throws {
        let pid = application.processIdentifier
        let sockets = try? capture("/usr/sbin/lsof", ["-n", "-a", "-p", String(pid), "-U", "-Fn"])
        guard let socket = sockets?.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("n/") && $0.hasSuffix("/gui-sock-\(pid)") }) else {
            throw NSError(domain: "WezTerm", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到当前 WezTerm 实例的连接。请检查终端后重试。"])
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WEZTERM_PANE")
        environment["WEZTERM_UNIX_SOCKET"] = String(socket.dropFirst())
        let cli = executable.deletingLastPathComponent().appendingPathComponent("wezterm")
        _ = try capture(cli.path, ["cli", "--no-auto-start", "spawn", "--cwd", cwd, "--", "/bin/sh", script.path], environment: environment)
    }
    func openGhosttyTab(application: NSRunningApplication, script: URL, cwd: String) throws {
        func code(_ value: StaticString) -> FourCharCode {
            value.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | FourCharCode($1) } }
        }
        let target = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: code("Ghst"), eventID: code("NTab"), targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let configuration = NSAppleEventDescriptor.record()
        configuration.setDescriptor(NSAppleEventDescriptor(string: "/bin/sh " + quote(script.path)), forKeyword: code("GScC"))
        configuration.setDescriptor(NSAppleEventDescriptor(string: cwd), forKeyword: code("GScD"))
        event.setParam(configuration, forKeyword: code("GNtS"))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 30)
            if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
                let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "Ghostty 脚本错误 \(number)"
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(number), userInfo: [NSLocalizedDescriptionKey: message])
            }
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errAEEventNotPermitted) {
            throw NSError(domain: error.domain, code: error.code, userInfo: [NSLocalizedDescriptionKey: "请在系统偏好设置的「安全性与隐私」中允许 Jotport 自动化控制 Ghostty。"])
        }
    }
    func confirmLaunch(_ runID: String, application: NSRunningApplication, deadline: TimeInterval) {
        if FileManager.default.fileExists(atPath: launchMarker(runID).path) {
            finishLaunch(runID, status: "终端已执行启动脚本，等待会话。", application: application)
        } else if application.isTerminated || ProcessInfo.processInfo.systemUptime >= deadline {
            finishLaunch(runID, status: "未确认终端执行启动脚本。点击「启动 / 返回」可核对后重试。")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.confirmLaunch(runID, application: application, deadline: deadline)
            }
        }
    }
    func finishLaunch(_ runID: String, status: String, application: NSRunningApplication? = nil) {
        terminalLaunchPaths.removeValue(forKey: runID)
        guard let i = blocks.firstIndex(where: { $0.run?.id == runID }) else { return }
        if blocks[i].run?.status == "启动中" { blocks[i].run?.status = status }
        if let application {
            blocks[i].run?.terminal?.processID = application.processIdentifier
            blocks[i].run?.terminal?.launchedAt = application.launchDate
        }
        save(i); reload()
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
