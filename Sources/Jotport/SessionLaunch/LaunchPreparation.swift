#if os(macOS)
import Darwin
import Foundation
import JotportCore

struct LaunchOptions {
    enum Agent: String, CaseIterable {
        case codex, pi
    }

    enum Terminal: String, CaseIterable {
        case wezTerm = "WezTerm"
        case ghostty = "Ghostty"

        var defaultPath: String { "/Applications/\(rawValue).app" }
    }

    let agent: Agent
    let terminal: Terminal

    static func saved(in preferences: UserDefaults = .standard) -> Self {
        let agent = preferences.string(forKey: "agent").flatMap(Agent.init(rawValue:)) ?? .codex
        let terminal = preferences.string(forKey: "terminal").flatMap(Terminal.init(rawValue:)) ?? .wezTerm
        return Self(agent: agent, terminal: terminal)
    }

    static func defaultAgentPaths() -> (codex: String, pi: String) {
        let environment = AgentEnvironment()
        return (environment.defaultPath(for: .codex), environment.defaultPath(for: .pi))
    }
}

struct LaunchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func captureLaunchOutput(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if process.isRunning { process.terminate() }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8)
    guard process.terminationStatus == 0 else { throw LaunchFailure(message: text ?? "探测失败") }
    return text ?? ""
}

private struct AgentEnvironment {
    private let inherited: [String: String]
    private let searchPath: String
    private static let unsetVariables = ["_VOLTA_TOOL_RECURSION"]

    init(inherited: [String: String] = ProcessInfo.processInfo.environment) {
        self.inherited = inherited
        let fallback = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if let shell = getpwuid(getuid())?.pointee.pw_shell,
           let output = try? captureLaunchOutput(String(cString: shell), ["-lc", "/usr/bin/printenv PATH"], environment: inherited),
           let path = output.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") {
            searchPath = String(path)
        } else {
            searchPath = fallback
        }
    }

    var probeVariables: [String: String] {
        var environment = inherited
        environment["PATH"] = searchPath
        for variable in Self.unsetVariables { environment.removeValue(forKey: variable) }
        return environment
    }

    var shellCommands: String {
        (["export PATH=\(shellQuote(searchPath))"] + Self.unsetVariables.map { "unset \($0)" }).joined(separator: "\n")
    }

    func defaultPath(for agent: LaunchOptions.Agent) -> String {
        let name = agent.rawValue
        let home = FileManager.default.homeDirectoryForCurrentUser
        let npmGlobal = agent == .codex ? [home.appendingPathComponent(".npm-global/bin/codex").path] : []
        let system = "/usr/local/bin/\(name)"
        let local = home.appendingPathComponent(".local/bin/\(name)").path
        let candidates = npmGlobal + [system, local] + searchPath.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? system
    }
}

struct LaunchPreparation {
    struct Prepared {
        let run: Run
        let terminal: TerminalApplication
        let script: URL
    }

    let root: URL
    let preferences: UserDefaults
    private let inheritedEnvironment: [String: String]

    init(root: URL, preferences: UserDefaults, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        self.preferences = preferences
        self.inheritedEnvironment = inheritedEnvironment
    }

    func terminalURL(for terminal: LaunchOptions.Terminal) -> URL {
        let path = preferences.string(forKey: terminal.rawValue + "App") ?? terminal.defaultPath
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    func marker(for runID: String) -> URL {
        runDirectory(for: runID).appendingPathComponent("started")
    }

    private func runDirectory(for runID: String) -> URL {
        root.appendingPathComponent("runs").appendingPathComponent(runID)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func prepare(options: LaunchOptions, terminalURL: URL, cwd: String, snapshot: String, sessionID: String?) throws -> Prepared {
        let terminal = try TerminalApplication(kind: options.terminal, url: terminalURL)
        guard Self.isDirectory(cwd) else {
            throw LaunchFailure(message: "工作目录不可用：\(cwd)")
        }
        let environment = AgentEnvironment(inherited: inheritedEnvironment)
        let probeEnvironment = environment.probeVariables
        let agent = options.agent
        let cli = preferences.string(forKey: agent.rawValue + "Path") ?? environment.defaultPath(for: agent)
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            throw LaunchFailure(message: "无法执行 \(agent.rawValue)。请在设置中检查路径 \(cli)")
        }
        try writeDiagnostics(terminal: terminal, cli: cli, environment: probeEnvironment)
        let arguments = Data((preferences.string(forKey: "arguments") ?? "[]").utf8)
        guard let extra = try? JSONDecoder().decode([String].self, from: arguments) else {
            throw LaunchFailure(message: "参数必须是 JSON 字符串数组")
        }
        guard extra.isEmpty else {
            throw LaunchFailure(message: "测试版暂不执行自定义参数，以避免位置参数被 CLI 当作初始 prompt 自动发送。")
        }

        var run = Run(snapshot: snapshot)
        run.terminal = terminal.reference
        let directory = runDirectory(for: run.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let snapshotURL = directory.appendingPathComponent("snapshot.txt")
        try snapshot.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let command = agentCommand(agent, cli: cli, sessionID: sessionID, environment: probeEnvironment)
        let script = """
        #!/bin/sh
        cd \(shellQuote(cwd)) || exit 1
        \(environment.shellCommands)
        export JOTPORT_RUN=\(shellQuote(run.id))
        export JOTPORT_INBOX=\(shellQuote(root.appendingPathComponent("inbox").path))
        export JOTPORT_SNAPSHOT=\(shellQuote(sessionID == nil ? snapshotURL.path : ""))
        export JOTPORT_RUN_DIR=\(shellQuote(directory.path))
        : > \(shellQuote(marker(for: run.id).path)) || exit 1
        \(command)
        """
        let scriptURL = directory.appendingPathComponent("launch.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        return Prepared(run: run, terminal: terminal, script: scriptURL)
    }

    private func writeDiagnostics(terminal: TerminalApplication, cli: String, environment: [String: String]) throws {
        let version = try captureLaunchOutput(cli, ["--version"], environment: environment)
        let help = try captureLaunchOutput(terminal.executable.path, ["--help"])
        let dictionary = (try? captureLaunchOutput("/usr/bin/sdef", [terminal.url.path])) ?? "无可用脚本字典；不使用未经验证的 AppleScript 接口"
        let diagnostics = """
        path=\(terminal.url.path)
        identity=\(terminal.identity)
        appVersion=\(terminal.version)
        build=\(terminal.build)
        agentPath=\(cli)
        agent=\(version)
        help=\(help)
        sdef=\(dictionary)
        """
        try diagnostics.write(to: root.appendingPathComponent("last-probe.txt"), atomically: true, encoding: .utf8)
    }

    private func agentCommand(_ agent: LaunchOptions.Agent, cli: String, sessionID: String?, environment: [String: String]) -> String {
        if agent == .codex, let helper = Bundle.main.executableURL,
           let serverHelp = try? captureLaunchOutput(cli, ["app-server", "--help"], environment: environment),
           serverHelp.contains("--ws-token-file"),
           let cliHelp = try? captureLaunchOutput(cli, ["--help"], environment: environment),
           cliHelp.contains("--remote-auth-token-env") {
            return CodexBridge.launchCommand(helper: helper, cli: cli, sessionID: sessionID, quote: shellQuote)
        }
        var arguments = [cli]
        if let sessionID {
            arguments += [agent == .codex ? "resume" : "--session", sessionID]
        }
        if agent == .pi, let extensionURL = Bundle.main.url(forResource: "jotport", withExtension: "ts") {
            arguments += ["--extension", extensionURL.path]
        }
        return "exec \(arguments.map(shellQuote).joined(separator: " "))"
    }
}
#endif
