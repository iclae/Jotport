#if os(macOS)
import Darwin
import Foundation
import JotportCore

final class CodexBridge {
    static let argument = "--codex-bridge"

    static func launchCommand(helper: URL, cli: String, sessionID: String?, quote: (String) -> String) -> String {
        let helperArguments = [helper.path, argument, cli] + [sessionID].compactMap { $0 }
        let resumeArguments = sessionID.map { " resume " + quote($0) } ?? ""
        let localCommand = quote(cli) + resumeArguments
        return """
        \(helperArguments.map(quote).joined(separator: " ")) 2>"$JOTPORT_RUN_DIR/codex-bridge.log" &
        bridge=$!
        trap 'kill "$bridge" 2>/dev/null || :' EXIT
        trap 'exit 129' HUP
        trap 'exit 143' TERM
        for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            [ -f "$JOTPORT_RUN_DIR/codex-endpoint" ] && break
            kill -0 "$bridge" 2>/dev/null || break
            sleep 0.25
        done
        if [ -f "$JOTPORT_RUN_DIR/codex-endpoint" ]; then
            endpoint=$(/bin/cat "$JOTPORT_RUN_DIR/codex-endpoint")
            JOTPORT_CODEX_TOKEN=$(/bin/cat "$JOTPORT_RUN_DIR/codex-token") \
                \(quote(cli)) --remote "$endpoint" --remote-auth-token-env JOTPORT_CODEX_TOKEN\(resumeArguments)
            exit $?
        fi
        kill "$bridge" 2>/dev/null || :
        trap - EXIT
        printf '%s\\n' 'Jotport 未能连接 Codex 状态服务。此会话仍可在终端中使用。' >&2
        exec \(localCommand)
        """
    }

    static func run(executable: String, expectedSessionID: String?) {
        let environment = ProcessInfo.processInfo.environment
        guard let runID = environment["JOTPORT_RUN"], let inbox = environment["JOTPORT_INBOX"],
              let directory = environment["JOTPORT_RUN_DIR"] else { exit(1) }
        let bridge = CodexBridge(runID: runID, inbox: URL(fileURLWithPath: inbox),
                                 directory: URL(fileURLWithPath: directory), expectedSessionID: expectedSessionID)
        do {
            try bridge.start(executable)
        } catch {
            FileHandle.standardError.write(Data("Codex 状态连接启动失败。\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        withExtendedLifetime(bridge) { dispatchMain() }
    }

    private let runID: String
    private let inbox: URL
    private let directory: URL
    private let expectedSessionID: String?
    private let token = UUID().uuidString + UUID().uuidString
    private let server = Process()
    private let output = Pipe()
    private let dateFormatter = ISO8601DateFormatter()
    private var signals: [DispatchSourceSignal] = []
    private var startupOutput = Data()
    private var connection: URLSessionWebSocketTask?
    private var endpoint: URL?
    private var sessionID: String?
    private var sequence = 0
    private var turn = 0
    private var active = false
    private var status: String?
    private var turnStartedAt: Int?
    private var lastSettledTurnID: String?

    private init(runID: String, inbox: URL, directory: URL, expectedSessionID: String?) {
        self.runID = runID
        self.inbox = inbox
        self.directory = directory
        self.expectedSessionID = expectedSessionID
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private func start(_ executable: String) throws {
        for number in [SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(exited: true) }
            source.resume()
            signals.append(source)
        }

        let tokenFile = directory.appendingPathComponent("codex-token")
        try token.write(to: tokenFile, atomically: true, encoding: .utf8)
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["app-server", "--listen", "ws://127.0.0.1:0",
                            "--ws-auth", "capability-token", "--ws-token-file", tokenFile.path]
        server.standardInput = FileHandle.nullDevice
        server.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.readServerOutput(data) }
        }
        server.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.finish(exited: false) }
        }
        try server.run()
    }

    private func readServerOutput(_ data: Data) {
        guard endpoint == nil else { return }
        startupOutput.append(data)
        while let newline = startupOutput.firstIndex(of: 10) {
            let line = String(decoding: startupOutput[..<newline], as: UTF8.self)
            startupOutput.removeSubrange(...newline)
            let prefix = "  listening on: ws://127.0.0.1:"
            guard line.hasPrefix(prefix), let port = UInt16(line.dropFirst(prefix.count)), port > 0,
                  let url = URL(string: "ws://127.0.0.1:\(port)") else {
                FileHandle.standardError.write(Data((line + "\n").utf8))
                continue
            }
            endpoint = url
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            connection = socket
            socket.resume()
            send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "jotport", "version": "0.1"]]])
            receive()
            return
        }
    }

    private func send(_ request: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        connection?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive() {
        connection?.receive { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(.string(let message)):
                    if let object = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] {
                        self.handle(object)
                    }
                case .failure(let error):
                    FileHandle.standardError.write(Data("Codex 状态连接中断。\(error.localizedDescription)\n".utf8))
                    self.emit("unknown")
                    return
                default:
                    break
                }
                self.receive()
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            if id == 0, message["result"] != nil, let endpoint {
                send(["method": "initialized"])
                try? endpoint.absoluteString.write(to: directory.appendingPathComponent("codex-endpoint"),
                                                   atomically: true, encoding: .utf8)
            } else if id > 0, id == turn, !active {
                let result = message["result"] as? [String: Any]
                let latestTurn = (result?["data"] as? [[String: Any]])?.first
                if let latestID = latestTurn?["id"] as? String, latestID != lastSettledTurnID,
                   let startedAt = latestTurn?["startedAt"] as? Int, let turnStartedAt,
                   startedAt >= turnStartedAt, latestTurn?["status"] as? String == "completed" {
                    lastSettledTurnID = latestID
                    emit("settled")
                } else {
                    emit("idle")
                }
            }
            return
        }

        guard let params = message["params"] as? [String: Any] else { return }
        switch message["method"] as? String {
        case "thread/started":
            guard let thread = params["thread"] as? [String: Any], let id = thread["id"] as? String,
                  thread["source"] is String, sessionID == nil, expectedSessionID == nil || expectedSessionID == id else { return }
            sessionID = id
            emit("bound")
        case "thread/status/changed":
            guard let id = params["threadId"] as? String, id == (sessionID ?? expectedSessionID),
                  let state = params["status"] as? [String: Any] else { return }
            sessionID = id
            switch state["type"] as? String {
            case "active":
                if !active {
                    turn += 1
                    turnStartedAt = (message["emittedAtMs"] as? Int).map { $0 / 1_000 }
                }
                active = true
                let flags = state["activeFlags"] as? [String] ?? []
                emit(flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? "waiting" : "running")
            case "idle":
                if active {
                    active = false
                    send(["id": turn, "method": "thread/turns/list", "params": ["threadId": id, "limit": 1]])
                } else if status == nil {
                    emit("bound")
                }
            case "systemError", "notLoaded":
                active = false
                emit("unknown")
            default:
                break
            }
        default:
            break
        }
    }

    private func emit(_ type: String) {
        guard let sessionID, status != type else { return }
        let event = BridgeEvent(schemaVersion: 1, eventID: UUID().uuidString, runID: runID,
                                sessionID: sessionID, turnID: turn, sequence: sequence,
                                source: "codex", type: type, time: dateFormatter.string(from: Date()))
        let path = inbox.appendingPathComponent(event.eventID + ".json")
        do {
            try JSONEncoder().encode(event).write(to: path, options: .atomic)
            sequence += 1
            status = type
        } catch {
            FileHandle.standardError.write(Data("Codex 状态写入失败。\(error.localizedDescription)\n".utf8))
        }
    }

    private func finish(exited: Bool) -> Never {
        emit(exited ? "exited" : "unknown")
        connection?.cancel()
        if server.isRunning { server.terminate() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("codex-token"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("codex-endpoint"))
        exit(exited ? 0 : 1)
    }
}
#endif
