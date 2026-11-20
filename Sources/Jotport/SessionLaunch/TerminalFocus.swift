#if os(macOS)
import AppKit
import JotportCore

/// Only addresses a recorded instance and pane. Never starts a terminal or agent.
enum TerminalFocus {
    static func perform(_ reference: TerminalRef, completion: @escaping (Result<Void, Error>) -> Void) {
        guard reference.terminalKind == LaunchOptions.Terminal.wezTerm.rawValue else {
            completion(.failure(LaunchFailure(message: "此绑定没有可验证的窗格定位信息。Ghostty 的精确返回尚未接入，旧绑定也不能自动补猜。")))
            return
        }
        guard let process = TerminalAccess.system.locate(reference) else {
            completion(.failure(LaunchFailure(message: "原终端进程已退出或身份已改变。确认会话已退出后可使用「按原 ID 恢复」。")))
            return
        }
        DispatchQueue.global().async {
            let result = Result {
                guard let bundle = Bundle(path: reference.path), bundle.bundleIdentifier == reference.identity,
                      let executable = bundle.executableURL else {
                    throw LaunchFailure(message: "原终端安装路径或身份已改变，请检查设置。")
                }
                let sockets = try captureLaunchOutput("/usr/sbin/lsof", ["-n", "-a", "-p", String(process.processID), "-U", "-Fn"])
                try focusWezTerm(reference, sockets: sockets) { arguments, environment in
                    try captureLaunchOutput(executable.deletingLastPathComponent().appendingPathComponent("wezterm").path,
                                            arguments, environment: environment)
                }
            }
            DispatchQueue.main.async {
                guard TerminalAccess.system.locate(reference) != nil else {
                    completion(.failure(LaunchFailure(message: "聚焦期间原终端已退出。")))
                    return
                }
                // The CLI selects pane/tab, but does not raise an OS window. We only
                // foreground a verified single-window instance; multi-window is explicit failure.
                if case .success = result { process.activate() }
                completion(result)
            }
        }
    }

    static func focusWezTerm(_ reference: TerminalRef, sockets: String,
                             command: ([String], [String: String]) throws -> String) throws {
        guard let pane = reference.paneID, UInt64(pane) != nil,
              let socket = reference.socketPath, socket.hasPrefix("/"),
              let pid = reference.processID,
              socket.hasSuffix("/gui-sock-\(pid)"),
              sockets.split(whereSeparator: \.isNewline).contains(Substring("n" + socket)) else {
            throw LaunchFailure(message: "缺少有效窗格/实例记录，或原实例连接已失效。旧会话请手动定位；新启动的 WezTerm 会话会记录定位信息。")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WEZTERM_PANE")
        environment["WEZTERM_UNIX_SOCKET"] = socket
        let prefix = ["cli", "--no-auto-start"]
        struct Pane: Decodable { let pane_id: UInt64; let window_id: UInt64; let is_active: Bool }
        func target() throws -> Pane {
            let json = try command(prefix + ["list", "--format", "json"], environment)
            let panes = try JSONDecoder().decode([Pane].self, from: Data(json.utf8))
            guard Set(panes.map(\.window_id)).count == 1 else {
                throw LaunchFailure(message: "此 WezTerm 实例包含多个窗口或没有可用窗口。CLI 不能可靠前置指定系统窗口，请手动选择原窗口；未切换到其他会话。")
            }
            guard let found = panes.first(where: { String($0.pane_id) == pane }) else {
                throw LaunchFailure(message: "绑定窗格已关闭或不可达；不会选择其他窗格。")
            }
            return found
        }
        _ = try target()
        _ = try command(prefix + ["activate-pane", "--pane-id", pane], environment)
        guard try target().is_active else {
            throw LaunchFailure(message: "终端未确认绑定窗格已选中，请手动核对。")
        }
    }
}
#endif
