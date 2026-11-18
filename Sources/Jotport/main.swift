#if os(macOS)
import AppKit
import JotportCore

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    let table = NSTableView(), editor = NSTextView(), search = NSSearchField()
    let status = NSTextField(wrappingLabelWithString: ""), recap = NSTextField(wrappingLabelWithString: "")
    let include = NSButton(checkboxWithTitle: "包含归档", target: nil, action: nil)
    let agent = NSPopUpButton(), terminal = NSPopUpButton()
    var blocks: [Block] = [], rows: [String] = [], selected: String?
    var store: Store!
    var root: URL!
    var watcher: DispatchSourceFileSystemObject?
    var pendingPromotion: Set<String> = []
    var editing = false
    var processes: [Process] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jotport")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try Store(path: root.appendingPathComponent("notes.sqlite").path)
            blocks = try store.load()
            for i in blocks.indices where blocks[i].run != nil && blocks[i].run?.status != "已退出" { blocks[i].run?.status = "状态未知：需核对终端"; try store.save(blocks[i]) }
        } catch { fatalError("无法打开本地数据库：\(error)") }
        buildUI(); reload(); consume()
        let fd = open(root.appendingPathComponent("inbox").path, O_EVTONLY)
        if fd >= 0 {
            watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            watcher?.setEventHandler { [weak self] in self?.consume() }
            watcher?.setCancelHandler { close(fd) }; watcher?.resume()
        }
        if blocks.isEmpty { newBlock() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 980, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Jotport · 测试版"; window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Jotport", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""), editMenu = NSMenu()
        for (title, action, key) in [("撤销", "undo:", "z"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        search.placeholderString = "搜索正文、概况、会话 ID"; search.delegate = self
        include.target = self; include.action = #selector(refresh)
        agent.addItems(withTitles: ["codex", "pi"]); terminal.addItems(withTitles: ["WezTerm", "Ghostty"])
        agent.selectItem(withTitle: UserDefaults.standard.string(forKey: "agent") ?? "codex")
        terminal.selectItem(withTitle: UserDefaults.standard.string(forKey: "terminal") ?? "WezTerm")
        let top = NSStackView(views: [button("＋ 新建", #selector(newBlock)), search, include, button("窗口置顶", #selector(floatWindow)), button("设置", #selector(settings))])
        top.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block")); column.width = 260
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 62; table.delegate = self; table.dataSource = self
        table.registerForDraggedTypes([.string]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.widthAnchor.constraint(equalToConstant: 280).isActive = true
        editor.isRichText = false; editor.font = .systemFont(ofSize: 16); editor.allowsUndo = true; editor.delegate = self
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView(); textScroll.documentView = editor; textScroll.hasVerticalScroller = true
        let actions = NSStackView(views: [button("复制正文", #selector(copyBody)), button("置顶", #selector(pin)), button("归档/恢复", #selector(archive)), button("删除", #selector(remove)), button("撤销删除", #selector(undoDelete))])
        let launch = NSStackView(views: [terminal, agent, button("启动 / 返回", #selector(start)), button("按原 ID 恢复", #selector(resume)), button("复制会话 ID", #selector(copyID))])
        let right = NSStackView(views: [actions, textScroll, launch, status, recap]); right.orientation = .vertical; right.alignment = .leading
        textScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let main = NSStackView(views: [list, right]); main.orientation = .horizontal; main.distribution = .fill
        let all = NSStackView(views: [top, main]); all.orientation = .vertical; all.alignment = .leading; all.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(all)
        NSLayoutConstraint.activate([all.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12), all.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12), all.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12), all.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -12), main.widthAnchor.constraint(equalTo: all.widthAnchor), top.widthAnchor.constraint(equalTo: all.widthAnchor), main.heightAnchor.constraint(equalTo: all.heightAnchor, constant: -42)])
    }
    var index: Int? { blocks.firstIndex { $0.id == selected } }
    func save(_ i: Int) { do { try store.save(blocks[i]) } catch { alert("保存失败：\(error.localizedDescription)") } }
    func alert(_ text: String) { let a = NSAlert(); a.messageText = text; a.runModal() }
    func reload() {
        rows = blocks.filter { Reducer.matches($0, query: search.stringValue, archived: include.state == .on) }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.order < $1.order }.map(\.id)
        table.reloadData()
        if let id = selected, let row = rows.firstIndex(of: id) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    @objc func refresh() { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let b = blocks.first { $0.id == rows[row] }!
        let label = NSTextField(wrappingLabelWithString: "\(b.pinned ? "📌 " : "")\(b.archived ? "[归档] " : "")\(b.body.isEmpty ? "空白块" : String(b.body.prefix(70)))\n\(b.attention == nil ? "" : "● ")\(b.run?.status ?? "笔记")")
        label.font = .systemFont(ofSize: 12); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let id = rows[table.selectedRow]
        if id != selected { selected = id; editor.string = blocks[index!].body; editor.undoManager?.removeAllActions() }
        detail()
    }
    func detail() { guard let i = index else { return }; status.stringValue = blocks[i].run?.status ?? "正文自动保存；Enter 换行"; recap.stringValue = blocks[i].recap.isEmpty ? "暂无概况" : "最近回复摘录（可能过期）\n\(blocks[i].recap)\n\(blocks[i].recapSource)" }
    func textDidBeginEditing(_ notification: Notification) { editing = true }
    func textDidChange(_ notification: Notification) { guard let i = index else { return }; blocks[i].body = editor.string; blocks[i].revision += 1; blocks[i].updated = Date(); save(i) }
    func textDidEndEditing(_ notification: Notification) { editing = false; promote(); reload() }
    func controlTextDidChange(_ obj: Notification) { reload(); if search.stringValue.isEmpty { promote() } }
    @objc func newBlock() { var b = Block(); b.order = (blocks.map(\.order).min() ?? 0) - 1; blocks.append(b); selected = b.id; editor.string = ""; save(blocks.count - 1); reload(); window.makeFirstResponder(editor) }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    @objc func copyBody() { if let i = index { copy(blocks[i].body) } }
    @objc func copyID() { if let i = index { copy(blocks[i].association?.sessionID ?? "") } }
    @objc func pin() { if let i = index { blocks[i].pinned.toggle(); save(i); reload() } }
    @objc func archive() { if let i = index { blocks[i].archived.toggle(); save(i); reload() } }
    @objc func remove() { if let i = index { blocks[i].deleted = true; blocks[i].updated = Date(); save(i); selected = nil; editor.string = ""; reload() } }
    @objc func undoDelete() { if let b = blocks.filter({ $0.deleted }).max(by: { $0.updated < $1.updated }), let i = blocks.firstIndex(where: { $0.id == b.id }) { blocks[i].deleted = false; save(i); reload() } }
    @objc func floatWindow() { window.level = window.level == .floating ? .normal : .floating }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { let item = NSPasteboardItem(); item.setString(rows[row], forType: .string); return item }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation { tableView.setDropRow(row, dropOperation: .above); return .move }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard search.stringValue.isEmpty, let id = info.draggingPasteboard.string(forType: .string), let from = rows.firstIndex(of: id), let i = blocks.firstIndex(where: { $0.id == id }) else { return false }
        if row < rows.count, let target = blocks.first(where: { $0.id == rows[row] }), target.pinned != blocks[i].pinned { return false }
        var order = rows; order.remove(at: from); order.insert(id, at: min(order.count, max(0, row - (from < row ? 1 : 0))))
        for (rank, id) in order.enumerated() { let j = blocks.firstIndex { $0.id == id }!; blocks[j].order = Double(rank); save(j) }; reload(); return true
    }
    func consume() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("inbox"), includingPropertiesForKeys: nil) else { return }
        let events = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, BridgeEvent)? in guard let d = try? Data(contentsOf: url), d.count < 100_000, let e = try? JSONDecoder().decode(BridgeEvent.self, from: d) else { return nil }; return (url, e) }.sorted { $0.1.sequence < $1.1.sequence }
        for (url, event) in events {
            if let i = blocks.firstIndex(where: { $0.run?.id == event.runID }) {
                let old = blocks[i].attention
                if Reducer.apply(event, to: &blocks[i]) { do { try store.save(blocks[i]); if blocks[i].attention != old { pendingPromotion.insert(blocks[i].id) }; try? FileManager.default.removeItem(at: url) } catch { alert("事件保存失败：\(error)") } }
            }
        }
        promote(); detail()
    }
    func promote() {
        guard !editing, !editor.hasMarkedText(), search.stringValue.isEmpty else { return }
        for id in pendingPromotion { if let i = blocks.firstIndex(where: { $0.id == id }), !blocks[i].pinned, !blocks[i].archived, !blocks[i].deleted { blocks[i].order = (blocks.map(\.order).min() ?? 0) - 1; save(i) } }
        pendingPromotion.removeAll(); reload()
    }
    @objc func settings() {
        let a = NSAlert(); a.messageText = "首次接入设置"; a.informativeText = "选择终端实际 .app 路径。CLI 路径必须为可执行文件；参数为 JSON 字符串数组。不会更改 Codex/pi 全局配置。"
        let names = ["WezTermApp", "GhosttyApp", "codexPath", "piPath", "directory", "arguments"]
        let defaults = ["/Applications/WezTerm.app", "/Applications/Ghostty.app", "/usr/local/bin/codex", "/usr/local/bin/pi", FileManager.default.homeDirectoryForCurrentUser.path, "[]"]
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        var fields: [NSTextField] = []
        for (key, value) in zip(names, defaults) { stack.addArrangedSubview(NSTextField(labelWithString: key)); let f = NSTextField(string: UserDefaults.standard.string(forKey: key) ?? value); f.widthAnchor.constraint(equalToConstant: 500).isActive = true; stack.addArrangedSubview(f); fields.append(f) }
        stack.frame = NSRect(x: 0, y: 0, width: 500, height: 310); a.accessoryView = stack; a.addButton(withTitle: "保存"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { for (key, f) in zip(names, fields) { UserDefaults.standard.set(f.stringValue, forKey: key) }; UserDefaults.standard.set(agent.titleOfSelectedItem, forKey: "agent"); UserDefaults.standard.set(terminal.titleOfSelectedItem, forKey: "terminal") }
    }
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func capture(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        // Bound diagnostics; never used as an input-readiness signal.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "探测失败"]) }
        return String(data: data, encoding: .utf8) ?? ""
    }
    @objc func start() {
        guard let i = index else { return }
        if blocks[i].run != nil {
            consume()
            guard let ref = blocks[i].run?.terminal, let pid = ref.processID, let app = NSRunningApplication(processIdentifier: pid), app.bundleURL?.path == ref.path, app.launchDate == ref.launchedAt else { alert("状态未知，启动请求已保留，未重复启动。请核对终端；确认原运行退出后可按原 ID 恢复。"); return }
            // App activation is deliberately not claimed as exact pane focus.
            app.activate(options: [.activateIgnoringOtherApps]); status.stringValue = "已返回终端应用；具体 pane 尚未核验，请自行选择。未重复预填。"; return
        }
        launch(i, restoring: false)
    }
    @objc func resume() {
        guard let i = index, blocks[i].association?.sessionID != nil else { alert("尚无真实原生会话 ID，不能冒充恢复。pi 会自动上报；Codex 当前需完成正式 hooks 接入。"); return }
        guard blocks[i].run?.status == "已退出" else { alert("尚未确认对应运行退出；为防止重复运行，暂不恢复。"); return }
        launch(i, restoring: true)
    }
    func launch(_ i: Int, restoring: Bool) {
        let defaults = UserDefaults.standard
        let name = restoring ? blocks[i].association!.agent : (agent.titleOfSelectedItem ?? "codex")
        let term = terminal.titleOfSelectedItem ?? "WezTerm"
        let path = defaults.string(forKey: term + "App") ?? "/Applications/\(term).app"
        let cli = defaults.string(forKey: name + "Path") ?? "/usr/local/bin/\(name)"
        let cwd = restoring ? blocks[i].association!.directory : (defaults.string(forKey: "directory") ?? FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            guard let bundle = Bundle(path: path), let identity = bundle.bundleIdentifier, let terminalCLI = bundle.executableURL, FileManager.default.isExecutableFile(atPath: cli), FileManager.default.fileExists(atPath: cwd) else { settings(); return }
            let version = try capture(cli, ["--version"])
            let help = try capture(terminalCLI.path, ["--help"])
            let dictionary = (try? capture("/usr/bin/sdef", [path])) ?? "无可用脚本字典；不使用未经验证的 AppleScript 接口"
            let diagnostics = "path=\(path)\nidentity=\(identity)\nappVersion=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")\nbuild=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")\nagent=\(version)\nhelp=\(help)\nsdef=\(dictionary)"
            try diagnostics.write(to: root.appendingPathComponent("last-probe.txt"), atomically: true, encoding: .utf8)
            guard let argsData = (defaults.string(forKey: "arguments") ?? "[]").data(using: .utf8), let extra = try? JSONDecoder().decode([String].self, from: argsData) else { alert("参数必须是 JSON 字符串数组"); return }
            // Arbitrary positional prompts could submit content. This preview accepts no custom agent args.
            guard extra.isEmpty else { alert("测试版暂不执行自定义参数，以避免位置参数被 CLI 当作初始 prompt 自动发送。"); return }
            if term == "Ghostty", !help.contains("-e") { alert("当前 Ghostty 未探测到 -e 能力，未启动。诊断保存在 last-probe.txt。"); return }
            var run = Run(snapshot: restoring ? "" : blocks[i].body)
            run.terminal = TerminalRef(path: path, identity: identity, version: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")")
            if !restoring { blocks[i].association = Association(agent: name, directory: cwd) }
            blocks[i].run = run
            // Persist request before any external side effect; uncertain requests are never automatically replayed.
            try store.save(blocks[i])
            let dir = root.appendingPathComponent("runs/\(run.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try run.snapshot.write(to: dir.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
            var argv = [cli]
            if restoring, let id = blocks[i].association?.sessionID { argv += name == "codex" ? ["resume", id] : ["--session", id] }
            if name == "pi", let extensionURL = Bundle.main.url(forResource: "jotport", withExtension: "ts") { argv += ["--extension", extensionURL.path] }
            let environment = ["JOTPORT_RUN": run.id, "JOTPORT_INBOX": root.appendingPathComponent("inbox").path, "JOTPORT_SNAPSHOT": restoring ? "" : dir.appendingPathComponent("snapshot.txt").path, "JOTPORT_RUN_DIR": dir.path]
            let script = "#!/bin/sh\ncd " + quote(cwd) + " || exit 1\n" + environment.map { "export \($0.key)=\(quote($0.value))" }.joined(separator: "\n") + "\n" + argv.map(quote).joined(separator: " ") + "\n"
            let scriptURL = dir.appendingPathComponent("launch.sh"); try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            if term == "WezTerm" { p.executableURL = terminalCLI; p.arguments = ["start", "--cwd", cwd, "--", "/bin/sh", scriptURL.path] }
            else { p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", path, "--args", "-e", "/bin/sh", scriptURL.path] }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); processes.append(p)
            blocks[i].run?.status = "已请求打开，待粘贴；会话状态未知"
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }) { blocks[i].run?.terminal?.processID = app.processIdentifier; blocks[i].run?.terminal?.launchedAt = app.launchDate }
            try store.save(blocks[i]); detail(); reload()
        } catch {
            if blocks[i].run != nil { blocks[i].run?.status = "状态未知：\(error.localizedDescription)"; save(i) }
            alert("启动/探测未完成：\(error.localizedDescription)。未决请求不会自动重放。")
        }
    }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
#else
print("Jotport UI requires macOS 12 or newer. Run swift test for portable core validation.")
#endif
