import CSQLite
import Foundation
import XCTest
import JotportCore

final class SessionInboxTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var database: URL!
    private var store: Store!
    private var inbox: SessionInbox!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = root.appendingPathComponent("notes.sqlite")
        store = try Store(path: database.path)
        inbox = SessionInbox(directory: directory, store: store)
    }

    override func tearDownWithError() throws {
        inbox = nil
        store = nil
        try FileManager.default.removeItem(at: root)
    }

    func testSessionMismatchIsSavedBeforeItsFileIsRemoved() throws {
        var block = activeBlock()
        block.association?.sessionID = "original"
        block.run?.status = "运行中"
        try store.save(block)
        var blocks = try store.load()
        let wrongSession = try event(for: block, type: "settled", sequence: 4, session: "different")
        let mismatchFile = try deliver(wrongSession)

        XCTAssertNil(inbox.consume(into: &blocks))
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.run?.status, "状态未知：终端会话已切换")
        XCTAssertEqual(blocks, [saved])
        XCTAssertEqual(saved.association?.sessionID, "original")
        XCTAssertNil(saved.attention)
        XCTAssertFalse(exists(mismatchFile))

        _ = try deliver(event(for: block, type: "running", sequence: 3, session: "original"))
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(blocks.first?.run?.status, "运行中")
        _ = try deliver(wrongSession)
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(try store.load().first?.run?.status, "运行中")
        XCTAssertFalse(exists(mismatchFile))
    }

    func testDuplicateAndOutOfOrderEventsAreRemovedWithoutChangingTheBlock() throws {
        let block = activeBlock()
        try store.save(block)
        var blocks = [block]
        let running = try event(for: block, type: "running", sequence: 2, turn: 2)
        _ = try deliver(running)
        XCTAssertNil(inbox.consume(into: &blocks))
        let current = try store.load()
        XCTAssertEqual(current.first?.run?.status, "运行中")

        let files = [
            try deliver(running),
            try deliver(event(for: block, type: "settled", sequence: 1, turn: 2)),
            try deliver(event(for: block, type: "settled", sequence: 3, turn: 1)),
            try deliver(event(for: block, type: "settled", sequence: 4, turn: 2, source: "codex"))
        ]
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(blocks, current)
        XCTAssertEqual(try store.load(), current)
        XCTAssertFalse(files.contains(where: exists))
    }

    func testLateEventsFillOnlyTheMissingHistoricalSessionID() throws {
        var block = activeBlock()
        let lateEvent = try event(for: block, type: "settled", sequence: 1, session: "original")
        let wrongSource = try event(for: block, type: "running", sequence: 0, session: "other", source: "codex")
        block.clearBinding()
        block.association = Association(agent: "pi", directory: "/Projects/Second")
        block.run = Run(snapshot: "second")
        try store.save(block)
        var blocks = try store.load()
        let lateFile = try deliver(lateEvent)
        let wrongFile = try deliver(wrongSource)

        XCTAssertNil(inbox.consume(into: &blocks))
        let saved = try XCTUnwrap(store.load().first)
        XCTAssertTrue(Reducer.matches(saved, query: "original", archived: false))
        XCTAssertEqual(saved.history.first?.sessionID, "original")
        XCTAssertEqual(saved.association, block.association)
        XCTAssertEqual(saved.run, block.run)
        XCTAssertNil(saved.attention)
        XCTAssertFalse(exists(lateFile))
        XCTAssertFalse(exists(wrongFile))

        _ = try deliver(lateEvent)
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertFalse(exists(lateFile))
        XCTAssertEqual(try store.load(), [saved])
    }

    func testInitialPrefillNeverCompletes() throws {
        let block = activeBlock()
        var blocks = [block]
        _ = try deliver(event(for: block, type: "prefilled", sequence: 0, turn: 0))
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(blocks.first?.run?.status, "待发送")
        XCTAssertNil(blocks.first?.attention)

        _ = try deliver(event(for: block, type: "settled", sequence: 1, turn: 0))
        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(try store.load().first?.run?.status, "待发送")
        XCTAssertNil(blocks.first?.attention)
    }

    func testFilesWithoutARecognizedEventOrRunStayInTheInbox() throws {
        let block = activeBlock()
        let oldEvent = try event(for: block, type: "exited", sequence: 0)
        var replacement = block
        replacement.run = Run(snapshot: "new")
        try store.save(replacement)
        var blocks = [replacement]
        let unmatched = try deliver(oldEvent)
        let malformed = directory.appendingPathComponent("malformed.json")
        try Data("{".utf8).write(to: malformed)
        var unsupportedEvent = try event(for: replacement, type: "running", sequence: 1)
        unsupportedEvent.schemaVersion = 2
        let unsupported = try deliver(unsupportedEvent)

        XCTAssertNil(inbox.consume(into: &blocks))
        XCTAssertEqual(blocks, [replacement])
        XCTAssertEqual(try store.load(), [replacement])
        XCTAssertTrue([unmatched, malformed, unsupported].allSatisfy(exists))
    }

    func testWriteFailureRetainsEventsAndRetriesTheRunInOrder() throws {
        let block = activeBlock()
        let independent = activeBlock()
        try store.save([block, independent])
        var blocks = [block, independent]
        let later = try deliver(event(for: block, type: "running", sequence: 2, turn: 2))
        let failed = try deliver(event(for: block, type: "settled", sequence: 1, text: "retry-recap"))
        let other = try deliver(event(for: independent, type: "running", sequence: 1))
        try executeSQL("""
            CREATE TRIGGER reject_reply BEFORE INSERT ON blocks
            WHEN instr(CAST(NEW.payload AS TEXT), 'retry-recap') > 0
            BEGIN SELECT RAISE(ABORT, 'write failure'); END;
            """)

        XCTAssertNotNil(inbox.consume(into: &blocks))
        XCTAssertEqual(blocks.first, block)
        XCTAssertEqual(try store.load().first(where: { $0.id == block.id }), block)
        XCTAssertTrue(exists(failed))
        XCTAssertTrue(exists(later))
        XCTAssertFalse(exists(other))
        XCTAssertEqual(try store.load().first(where: { $0.id == independent.id })?.run?.status, "运行中")

        try executeSQL("DROP TRIGGER reject_reply")
        XCTAssertNil(inbox.consume(into: &blocks))
        let saved = try XCTUnwrap(store.load().first(where: { $0.id == block.id }))
        XCTAssertEqual(saved.run?.status, "运行中")
        XCTAssertEqual(saved.recap, "retry-recap")
        XCTAssertNotNil(saved.attention)
        XCTAssertEqual(blocks.first, saved)
        XCTAssertFalse(exists(failed))
        XCTAssertFalse(exists(later))
    }

    private func activeBlock() -> Block {
        var block = Block()
        block.association = Association(agent: "pi", directory: "/Projects/Original")
        block.run = Run(snapshot: "first")
        return block
    }

    private func event(for block: Block, type: String, sequence: Int, turn: Int = 1,
                       session: String = "real-id", source: String = "pi", text: String? = nil) throws -> BridgeEvent {
        BridgeEvent(schemaVersion: 1, eventID: UUID().uuidString, runID: try XCTUnwrap(block.run?.id),
                    sessionID: session, turnID: turn, sequence: sequence, source: source,
                    type: type, time: "2026-01-01T00:00:00Z", text: text)
    }

    private func deliver(_ event: BridgeEvent) throws -> URL {
        let file = directory.appendingPathComponent(event.eventID + ".json")
        try JSONEncoder().encode(event).write(to: file)
        return file
    }

    private func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private func executeSQL(_ sql: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open(database.path, &handle)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(status, SQLITE_OK)
        let result = sqlite3_exec(try XCTUnwrap(handle), sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
