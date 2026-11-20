#if os(macOS)
import AppKit
import Carbon
import JotportCore

struct TerminalApplication {
    let kind: LaunchOptions.Terminal
    let url: URL
    let identity: String
    let executable: URL
    let version: String
    let build: String

    init(kind: LaunchOptions.Terminal, url: URL) throws {
        guard let bundle = Bundle(url: url), let identity = bundle.bundleIdentifier, let executable = bundle.executableURL else {
            throw LaunchFailure(message: "找不到 \(kind.rawValue) 安装包。请在设置中检查路径 \(url.path)")
        }
        self.kind = kind
        self.url = url
        self.identity = identity
        self.executable = executable
        version = "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")"
        build = "\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")"
    }

    var reference: TerminalRef {
        var result = TerminalRef(path: url.path, identity: identity, version: version)
        result.terminalKind = kind.rawValue
        return result
    }

    fileprivate func open(_ script: URL, cwd: String, completion: @escaping (Result<TerminalAccess.Opened, Error>) -> Void) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identity)
        let existing = running.filter { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == url.path }
        if let application = existing.first(where: \.isActive) ?? existing.first {
            DispatchQueue.global().async {
                let result = Result {
                    try openTab(application, script: script, cwd: cwd)
                    return TerminalAccess.Opened(process: TerminalAccess.Process(application), inExistingApplication: true)
                }.mapError { error in
                    LaunchFailure(message: "无法在 \(kind.rawValue) 打开标签页。\(error.localizedDescription)") as Error
                }
                DispatchQueue.main.async { completion(result) }
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = !running.isEmpty
        switch kind {
        case .wezTerm:
            configuration.arguments = ["start", "--always-new-process", "--cwd", cwd, "--", "/bin/sh", script.path]
        case .ghostty:
            configuration.arguments = ["-e", "/bin/sh", script.path]
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            DispatchQueue.main.async {
                if let application {
                    completion(.success(TerminalAccess.Opened(process: TerminalAccess.Process(application), inExistingApplication: false)))
                } else {
                    completion(.failure(LaunchFailure(message: "打开 \(kind.rawValue) 失败。\(error?.localizedDescription ?? "系统未返回启动结果。")")))
                }
            }
        }
    }

    private func openTab(_ application: NSRunningApplication, script: URL, cwd: String) throws {
        switch kind {
        case .wezTerm:
            try openWezTermTab(application: application, script: script, cwd: cwd)
        case .ghostty:
            try openGhosttyTab(application: application, script: script, cwd: cwd)
        }
    }

    private func openWezTermTab(application: NSRunningApplication, script: URL, cwd: String) throws {
        let pid = application.processIdentifier
        let sockets = try? captureLaunchOutput("/usr/sbin/lsof", ["-n", "-a", "-p", String(pid), "-U", "-Fn"])
        guard let socket = sockets?.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("n/") && $0.hasSuffix("/gui-sock-\(pid)") }) else {
            throw LaunchFailure(message: "未找到当前 WezTerm 实例的连接。请检查终端后重试。")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WEZTERM_PANE")
        environment["WEZTERM_UNIX_SOCKET"] = String(socket.dropFirst())
        let cli = executable.deletingLastPathComponent().appendingPathComponent("wezterm")
        _ = try captureLaunchOutput(cli.path, ["cli", "--no-auto-start", "spawn", "--cwd", cwd, "--", "/bin/sh", script.path], environment: environment)
    }

    private func openGhosttyTab(application: NSRunningApplication, script: URL, cwd: String) throws {
        func code(_ value: StaticString) -> FourCharCode {
            value.withUTF8Buffer { bytes in bytes.reduce(0) { ($0 << 8) | FourCharCode($1) } }
        }
        let target = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: code("Ghst"), eventID: code("NTab"), targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let configuration = NSAppleEventDescriptor.record()
        configuration.setDescriptor(NSAppleEventDescriptor(string: "/bin/sh " + shellQuote(script.path)), forKeyword: code("GScC"))
        configuration.setDescriptor(NSAppleEventDescriptor(string: cwd), forKeyword: code("GScD"))
        event.setParam(configuration, forKeyword: code("GNtS"))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 30)
            if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
                let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "Ghostty 脚本错误 \(number)"
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(number), userInfo: [NSLocalizedDescriptionKey: message])
            }
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errAEEventNotPermitted) {
            throw LaunchFailure(message: "请在系统偏好设置的「安全性与隐私」中允许 Jotport 自动化控制 Ghostty。")
        }
    }
}

struct TerminalAccess {
    struct Process {
        let processID: Int32
        let launchedAt: Date?
        let isTerminated: () -> Bool
        let activate: () -> Void
    }

    struct Opened {
        let process: Process
        let inExistingApplication: Bool
    }

    let locate: (TerminalRef) -> Process?
    let open: (TerminalApplication, URL, String, @escaping (Result<Opened, Error>) -> Void) -> Void

    var focus: (TerminalRef, @escaping (Result<Void, Error>) -> Void) -> Void = TerminalFocus.perform

    static let system = Self(
        locate: { reference in
            guard let pid = reference.processID, let launchedAt = reference.launchedAt,
                  let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated,
                  application.bundleURL?.resolvingSymlinksInPath().path == reference.path,
                  application.launchDate == launchedAt else { return nil }
            return Process(application)
        },
        open: { terminal, script, cwd, completion in
            terminal.open(script, cwd: cwd, completion: completion)
        }
    )
}

private extension TerminalAccess.Process {
    init(_ application: NSRunningApplication) {
        self.init(processID: application.processIdentifier, launchedAt: application.launchDate,
                  isTerminated: { application.isTerminated }, activate: { _ = application.activate(options: [.activateIgnoringOtherApps]) })
    }
}
#endif
