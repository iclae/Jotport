#if os(macOS)
import Foundation
import JotportCore

final class SessionLaunch {
    enum Action {
        case startOrReturn
        case startNew(LaunchOptions)
        case resume
        case changeDirectory
    }

    enum DirectoryPrompt {
        case initial
        case existing(String)
        case unavailable(String)
    }

    enum RetryChoice {
        case cancel
        case retry
        case returnToTerminal
    }

    struct Prompts {
        let directory: (DirectoryPrompt) -> String?
        let retry: (_ canReturn: Bool) -> RetryChoice
        let alert: (String) -> Void
    }

    private enum Attempt {
        case fresh
        case retry(runID: String)
        case resume(runID: String, sessionID: String)
    }

    private struct PendingLaunch {
        let blockID: String
        let terminalPath: String
    }

    private let preparation: LaunchPreparation
    private let store: Store
    private let blockForID: (String) -> Block?
    private let publish: (Block) -> Void
    private let prompts: Prompts
    private let terminals: TerminalAccess
    private var pending: [String: PendingLaunch] = [:]

    init(root: URL, store: Store, blockForID: @escaping (String) -> Block?, publish: @escaping (Block) -> Void,
         prompts: Prompts, preferences: UserDefaults = .standard, terminals: TerminalAccess = .system) {
        preparation = LaunchPreparation(root: root, preferences: preferences)
        self.store = store
        self.blockForID = blockForID
        self.publish = publish
        self.prompts = prompts
        self.terminals = terminals
    }

    static func canResume(_ block: Block) -> Bool {
        block.association?.sessionID != nil && block.run?.status == "已退出"
    }

    func markSessionsUnknownAfterRestart(_ blocks: inout [Block]) throws {
        for index in blocks.indices where blocks[index].run != nil && blocks[index].run?.status != "已退出" {
            blocks[index].run?.status = "状态未知：需核对终端"
            try store.save(blocks[index])
        }
    }

    func perform(_ action: Action, on blockID: String) {
        guard let block = blockForID(blockID), !block.deleted else { return }
        switch action {
        case .startOrReturn:
            startOrReturn(block)
        case let .startNew(options):
            launch(.fresh, from: block, options: options)
        case .resume:
            resume(block)
        case .changeDirectory:
            guard block.association == nil, let path = chooseDirectory(block.launchDirectory) else { return }
            _ = saveDirectory(path, for: blockID)
        }
    }

    private func startOrReturn(_ block: Block) {
        guard let run = block.run else {
            launch(.fresh, from: block, options: .saved(in: preparation.preferences))
            return
        }
        guard run.status != "启动中" else { return }
        let original = run.terminal.flatMap(terminals.locate)
        if canRetry(block, runID: run.id) {
            switch prompts.retry(original != nil) {
            case .cancel:
                break
            case .retry:
                launch(.retry(runID: run.id), from: block, options: .saved(in: preparation.preferences))
            case .returnToTerminal:
                guard let current = blockForID(block.id), !current.deleted, current.run?.id == run.id else { return }
                current.run?.terminal.flatMap(terminals.locate)?.activate()
            }
        } else if let original {
            original.activate()
        } else {
            prompts.alert("状态未知，启动请求已保留。请核对终端。确认原运行退出后可按原 ID 恢复。")
        }
    }

    private func resume(_ block: Block) {
        guard let association = block.association, let sessionID = association.sessionID else {
            prompts.alert("尚未收到会话 ID，无法恢复原会话。")
            return
        }
        guard Self.canResume(block), let run = block.run else {
            prompts.alert("尚未确认对应运行退出；为防止重复运行，暂不恢复。")
            return
        }
        guard let agent = LaunchOptions.Agent(rawValue: association.agent) else {
            prompts.alert("无法恢复 \(association.agent) 会话。当前版本支持 Codex 和 pi。")
            return
        }
        let terminal = LaunchOptions.saved(in: preparation.preferences).terminal
        launch(.resume(runID: run.id, sessionID: sessionID), from: block, options: LaunchOptions(agent: agent, terminal: terminal))
    }

    private func canRetry(_ block: Block, runID: String) -> Bool {
        block.run?.id == runID && block.association?.sessionID == nil && pending[runID] == nil &&
            !FileManager.default.fileExists(atPath: preparation.marker(for: runID).path)
    }

    private func launchableBlock(_ id: String, for attempt: Attempt) -> Block? {
        guard let block = blockForID(id), !block.deleted else { return nil }
        switch attempt {
        case .fresh:
            return block.run == nil && block.association == nil ? block : nil
        case let .retry(runID):
            return canRetry(block, runID: runID) ? block : nil
        case let .resume(runID, sessionID):
            return Self.canResume(block) && block.run?.id == runID && block.association?.sessionID == sessionID ? block : nil
        }
    }

    private func saveDirectory(_ path: String, for blockID: String) -> Bool {
        guard var block = blockForID(blockID), !block.deleted, block.association == nil else { return false }
        block.launchDirectory = path
        do {
            try store.save(block)
            publish(block)
            return true
        } catch {
            prompts.alert("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    private func launch(_ attempt: Attempt, from clicked: Block, options: LaunchOptions) {
        guard let block = launchableBlock(clicked.id, for: attempt) else { return }
        let cwd: String
        let sessionID: String?
        if case let .resume(_, originalSessionID) = attempt {
            guard let association = block.association else { return }
            cwd = association.directory
            sessionID = originalSessionID
        } else {
            sessionID = nil
            let path = block.launchDirectory ?? block.association?.directory
            if let path, LaunchPreparation.isDirectory(path) {
                cwd = path
            } else {
                guard let selected = chooseDirectory(path), launchableBlock(clicked.id, for: attempt) != nil else { return }
                if case .fresh = attempt, !saveDirectory(selected, for: clicked.id) { return }
                cwd = selected
            }
        }

        let terminalURL = preparation.terminalURL(for: options.terminal)
        let terminalPath = terminalURL.path
        guard !pending.values.contains(where: { $0.terminalPath == terminalPath }) else {
            prompts.alert("\(options.terminal.rawValue) 正在启动另一个会话。请稍后再试。")
            return
        }
        do {
            let prepared = try preparation.prepare(options: options, terminalURL: terminalURL, cwd: cwd,
                                                   snapshot: sessionID == nil ? clicked.body : "", sessionID: sessionID)
            guard var candidate = launchableBlock(clicked.id, for: attempt) else { return }
            if case .retry = attempt { candidate.clearBinding() }
            if sessionID == nil {
                candidate.launchDirectory = cwd
                candidate.association = Association(agent: options.agent.rawValue, directory: cwd)
            }
            candidate.run = prepared.run
            try store.save(candidate)

            let runID = prepared.run.id
            pending[runID] = PendingLaunch(blockID: candidate.id, terminalPath: terminalPath)
            publish(candidate)
            terminals.open(prepared.terminal, prepared.script, cwd) { [weak self] result in
                self?.terminalOpened(result, runID: runID)
            }
        } catch {
            prompts.alert("启动准备失败。\(error.localizedDescription)")
        }
    }

    private func terminalOpened(_ result: Result<TerminalAccess.Opened, Error>, runID: String) {
        switch result {
        case let .failure(error):
            finishLaunch(runID, status: error.localizedDescription)
        case let .success(opened):
            if opened.inExistingApplication, currentBlock(for: runID) != nil { opened.process.activate() }
            confirmLaunch(runID, process: opened.process, deadline: ProcessInfo.processInfo.systemUptime + 10)
        }
    }

    private func currentBlock(for runID: String) -> Block? {
        guard let request = pending[runID], let block = blockForID(request.blockID), block.run?.id == runID else { return nil }
        return block
    }

    private func confirmLaunch(_ runID: String, process: TerminalAccess.Process, deadline: TimeInterval) {
        if FileManager.default.fileExists(atPath: preparation.marker(for: runID).path) {
            finishLaunch(runID, status: "终端已执行启动脚本，等待会话。", process: process)
        } else if process.isTerminated() || ProcessInfo.processInfo.systemUptime >= deadline {
            finishLaunch(runID, status: "未确认终端执行启动脚本。点击「启动 / 返回」可核对后重试。")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.confirmLaunch(runID, process: process, deadline: deadline)
            }
        }
    }

    private func finishLaunch(_ runID: String, status: String, process: TerminalAccess.Process? = nil) {
        let current = currentBlock(for: runID)
        pending.removeValue(forKey: runID)
        guard var block = current, var run = block.run else { return }
        if run.status == "启动中" { run.status = status }
        if let process {
            run.terminal?.processID = process.processID
            run.terminal?.launchedAt = process.launchedAt
        }
        block.run = run
        let saved = Result { try store.save(block) }
        publish(block)
        if case let .failure(error) = saved {
            prompts.alert("保存失败：\(error.localizedDescription)")
        }
    }

    private func chooseDirectory(_ path: String?) -> String? {
        guard let path else { return prompts.directory(.initial) }
        return prompts.directory(LaunchPreparation.isDirectory(path) ? .existing(path) : .unavailable(path))
    }
}
#endif
