#if os(macOS)
import Foundation
import XCTest
import JotportCore
@testable import Jotport

final class SessionLaunchTests: XCTestCase {
    func testLaunchSavesBeforeOpeningAndReturnsToTheRecordedTerminal() throws {
        let fixture = try Fixture()
        var block = Block()
        block.body = "点击时的正文"
        try fixture.save(block)
        fixture.chooseDirectory = { [unowned fixture] _ in
            fixture.block.body = "选路径时编辑过的正文"
            return fixture.workingDirectory.path
        }

        fixture.perform(.startOrReturn)
        fixture.perform(.startOrReturn)
        let opening = try XCTUnwrap(fixture.openings.first)
        XCTAssertEqual(fixture.openings.count, 1)
        XCTAssertEqual(opening.saved?.body, "选路径时编辑过的正文")
        XCTAssertEqual(opening.saved?.run?.snapshot, "点击时的正文")
        XCTAssertEqual(opening.saved?.launchDirectory, fixture.workingDirectory.path)
        XCTAssertEqual(opening.saved?.run?.status, "启动中")
        let output = try fixture.execute(opening.script)
        XCTAssertEqual(output["cwd"], fixture.workingDirectory.path)
        XCTAssertEqual(output["snapshot"], opening.script.deletingLastPathComponent().appendingPathComponent("snapshot.txt").path)

        fixture.block.run?.status = "运行中"
        fixture.block.association?.sessionID = "session"
        try fixture.save(fixture.block)
        opening.complete(.success(.init(process: fixture.process(), inExistingApplication: true)))
        let saved = try XCTUnwrap(fixture.store.load().first)
        XCTAssertEqual(saved.run?.status, "运行中")
        XCTAssertEqual(saved.run?.terminal?.processID, 42)
        XCTAssertEqual(saved.run?.terminal?.launchedAt, fixture.launchDate)
        fixture.perform(.startOrReturn)
        XCTAssertEqual(fixture.activations, 2)
        XCTAssertEqual(fixture.openings.count, 1)
        XCTAssertTrue(fixture.alerts.isEmpty)
    }

    func testRetryRechecksTheMarkerAndRecordsThePreviousBinding() throws {
        let fixture = try Fixture()
        var block = Block()
        block.launchDirectory = fixture.workingDirectory.path
        try fixture.save(block)
        fixture.perform(.startOrReturn)
        let old = try XCTUnwrap(fixture.openings.first)
        let oldRun = try XCTUnwrap(old.saved?.run)
        old.complete(.success(.init(process: fixture.process(terminated: true), inExistingApplication: false)))
        XCTAssertTrue(fixture.block.run?.status.hasPrefix("未确认") == true)

        let marker = old.script.deletingLastPathComponent().appendingPathComponent("started")
        fixture.confirmRetry = { _ in
            do {
                try Data().write(to: marker)
                return .retry
            } catch {
                XCTFail(error.localizedDescription)
                return .cancel
            }
        }
        fixture.perform(.startOrReturn)
        XCTAssertEqual(fixture.openings.count, 1)
        XCTAssertEqual(fixture.block.run?.id, oldRun.id)

        try FileManager.default.removeItem(at: marker)
        fixture.confirmRetry = { _ in .retry }
        fixture.perform(.startOrReturn)
        XCTAssertEqual(fixture.openings.count, 2)
        XCTAssertNotEqual(fixture.block.run?.id, oldRun.id)
        XCTAssertEqual(fixture.block.history.first?.detachedRunID, oldRun.id)
    }

    func testResumingUsesTheOriginalSessionAndLeavesTheSnapshotEmpty() throws {
        let fixture = try Fixture()
        var block = Block()
        block.body = "恢复时不能发送这段正文"
        block.launchDirectory = "/不同的启动路径"
        block.association = Association(agent: "pi", directory: fixture.workingDirectory.path)
        block.association?.sessionID = "session 'original'"
        block.run = Run(snapshot: "旧快照")
        block.run?.status = "运行中"
        try fixture.save(block)
        fixture.preferences.set("codex", forKey: "agent")

        fixture.perform(.resume)
        XCTAssertTrue(fixture.openings.isEmpty)
        block.run?.status = "已退出"
        try fixture.save(block)
        fixture.perform(.resume)
        let opening = try XCTUnwrap(fixture.openings.first)
        XCTAssertEqual(opening.saved?.association, block.association)
        XCTAssertNotEqual(opening.saved?.run?.id, block.run?.id)
        XCTAssertEqual(opening.saved?.run?.snapshot, "")
        let output = try fixture.execute(opening.script)
        XCTAssertEqual(output["cwd"], fixture.workingDirectory.path)
        XCTAssertEqual(output["snapshot"], "")
        XCTAssertEqual(output["arg1"], "--session")
        XCTAssertEqual(output["arg2"], "session 'original'")
    }

    func testLateTerminalCallbackCannotReplaceTheNewRun() throws {
        let fixture = try Fixture()
        var block = Block()
        block.launchDirectory = fixture.workingDirectory.path
        try fixture.save(block)
        fixture.perform(.startOrReturn)
        let old = try XCTUnwrap(fixture.openings.first)
        _ = try fixture.execute(old.script)

        fixture.block.clearBinding()
        try fixture.save(fixture.block)
        fixture.perform(.startOrReturn)
        XCTAssertEqual(fixture.openings.count, 1)
        fixture.perform(.startNew(LaunchOptions(agent: .pi, terminal: .ghostty)))
        XCTAssertEqual(fixture.openings.count, 2)
        let latest = fixture.block

        old.complete(.success(.init(process: fixture.process(), inExistingApplication: true)))
        XCTAssertEqual(fixture.activations, 0)
        XCTAssertEqual(fixture.block, latest)
        XCTAssertEqual(try fixture.store.load(), [latest])
    }

    func testProbeAndScriptUseTheSamePathAndClearTheVoltaMarker() throws {
        let fixture = try Fixture()
        var inherited = ProcessInfo.processInfo.environment
        inherited["_VOLTA_TOOL_RECURSION"] = "inherited"
        let preparation = LaunchPreparation(root: fixture.root, preferences: fixture.preferences, inheritedEnvironment: inherited)
        let options = LaunchOptions(agent: .pi, terminal: .wezTerm)
        let launch = try preparation.prepare(options: options, terminalURL: preparation.terminalURL(for: .wezTerm),
                                             cwd: fixture.workingDirectory.path, snapshot: "", sessionID: nil)
        let diagnostics = try String(contentsOf: fixture.root.appendingPathComponent("last-probe.txt"), encoding: .utf8)
        let output = try fixture.execute(launch.script)
        let path = try XCTUnwrap(output["path"])
        XCTAssertTrue(diagnostics.contains("agent=path=\(path)\nvolta=unset\n"))
        XCTAssertEqual(output["volta"], "unset")
    }
}

private final class Fixture {
    struct Opening {
        let script: URL
        let saved: Block?
        let complete: (Result<TerminalAccess.Opened, Error>) -> Void
    }

    let root: URL
    let workingDirectory: URL
    let store: Store
    let preferences: UserDefaults
    let preferenceSuite: String
    let launchDate = Date()
    var block = Block()
    var openings: [Opening] = []
    var alerts: [String] = []
    var activations = 0
    var chooseDirectory: (SessionLaunch.DirectoryPrompt) -> String? = { _ in nil }
    var confirmRetry: (Bool) -> SessionLaunch.RetryChoice = { _ in .cancel }

    private lazy var launch = SessionLaunch(
        root: root, store: store,
        blockForID: { [unowned self] id in block.id == id ? block : nil },
        publish: { [unowned self] in block = $0 },
        prompts: .init(directory: { [unowned self] in chooseDirectory($0) },
                       retry: { [unowned self] in confirmRetry($0) },
                       alert: { [unowned self] in alerts.append($0) }),
        preferences: preferences,
        terminals: .init(locate: { [unowned self] reference in
            guard reference.processID == 42, reference.launchedAt == launchDate else { return nil }
            return process()
        }, open: { [unowned self] _, script, _, complete in
            openings.append(Opening(script: script, saved: try? store.load().first, complete: complete))
        })
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Jotport launch '\(UUID().uuidString)")
        workingDirectory = root.appendingPathComponent("work folder").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        store = try Store(path: root.appendingPathComponent("notes.sqlite").path)
        preferenceSuite = "JotportTests.\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceSuite))
        preferences.set("pi", forKey: "agent")
        let agent = root.appendingPathComponent("agent")
        try writeExecutable("""
            #!/bin/sh
            if [ "${1-}" = "--version" ]; then
                printf 'path=%s\nvolta=%s\n' "$PATH" "${_VOLTA_TOOL_RECURSION-unset}"
                exit 0
            fi
            printf 'path=%s\nvolta=%s\ncwd=%s\nsnapshot=%s\narg1=%s\narg2=%s\n' "$PATH" "${_VOLTA_TOOL_RECURSION-unset}" "$PWD" "$JOTPORT_SNAPSHOT" "${1-}" "${2-}" > "$JOTPORT_RUN_DIR/observed"
            """, to: agent)
        preferences.set(agent.path, forKey: "piPath")
        for terminal in LaunchOptions.Terminal.allCases {
            let app = root.appendingPathComponent(terminal.rawValue + ".app")
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/test-terminal")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeExecutable("#!/bin/sh\nprintf 'terminal help\\n'\n", to: executable)
            let info = ["CFBundleIdentifier": "dev.jotport.tests.\(terminal.rawValue)",
                        "CFBundleExecutable": "test-terminal", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            preferences.set(app.path, forKey: terminal.rawValue + "App")
        }
    }

    deinit {
        preferences.removePersistentDomain(forName: preferenceSuite)
        try? FileManager.default.removeItem(at: root)
    }

    func save(_ updated: Block) throws {
        try store.save(updated)
        block = updated
    }

    func perform(_ action: SessionLaunch.Action) {
        launch.perform(action, on: block.id)
    }

    func process(terminated: Bool = false) -> TerminalAccess.Process {
        .init(processID: 42, launchedAt: launchDate, isTerminated: { terminated }, activate: { [weak self] in self?.activations += 1 })
    }

    func execute(_ script: URL) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/different/terminal/path"
        environment["_VOLTA_TOOL_RECURSION"] = "from-terminal"
        _ = try captureLaunchOutput("/bin/sh", [script.path], environment: environment)
        let observed = try String(contentsOf: script.deletingLastPathComponent().appendingPathComponent("observed"), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: observed.split(whereSeparator: \.isNewline).compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        })
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
#endif
