import XCTest
@testable import JotportCore
final class CoreTests: XCTestCase {
    func testBlocksKeepTheirOwnLaunchDirectories() throws {
        let store = try Store(path: ":memory:")
        var first = Block()
        first.launchDirectory = "/Projects/Jotport"
        var second = Block()
        second.launchDirectory = "/Projects/Another Project"
        let unset = Block()
        try store.save([first, second, unset])

        let blocks = try store.load()
        XCTAssertEqual(blocks.first { $0.id == first.id }?.launchDirectory, "/Projects/Jotport")
        XCTAssertEqual(blocks.first { $0.id == second.id }?.launchDirectory, "/Projects/Another Project")
        XCTAssertNil(blocks.first { $0.id == unset.id }?.launchDirectory)
    }

    func testClearingBindingKeepsSessionSearchableAndReleasesBlock() throws {
        let store = try Store(path: ":memory:")
        var block = Block()
        block.body = "项目笔记"
        block.association = Association(agent: "pi", directory: "/Projects/Original")
        block.run = Run(snapshot: block.body)
        let reply = try event(block, "settled", sequence: 1)
        XCTAssertTrue(Reducer.apply(reply, to: &block))

        block.clearBinding()
        block.clearBinding()
        try store.save(block)

        var saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.body, "项目笔记")
        XCTAssertEqual(saved.launchDirectory, "/Projects/Original")
        XCTAssertNil(saved.association)
        XCTAssertNil(saved.run)
        XCTAssertNil(saved.attention)
        XCTAssertEqual(saved.history.map(\.sessionID), ["real-id"])
        XCTAssertTrue(Reducer.matches(saved, query: "real-id", archived: false))
        XCTAssertFalse(Reducer.apply(reply, to: &saved))
    }

    func testLateSessionIDUpdatesOnlyHistoryAfterClearingBinding() throws {
        let store = try Store(path: ":memory:")
        var block = Block()
        block.association = Association(agent: "pi", directory: "/Projects/Original")
        block.run = Run(snapshot: "first")
        let lateEvent = try event(block, "settled", sequence: 1, session: "original-id")
        block.clearBinding()
        block.launchDirectory = "/Projects/Second"
        block.association = Association(agent: "pi", directory: "/Projects/Second")
        block.run = Run(snapshot: "second")
        try store.save(block)

        var saved = try XCTUnwrap(store.load().first)
        XCTAssertTrue(Reducer.apply(lateEvent, to: &saved))
        XCTAssertTrue(Reducer.matches(saved, query: "original-id", archived: false))
        XCTAssertEqual(saved.association, block.association)
        XCTAssertEqual(saved.run, block.run)
        XCTAssertNil(saved.attention)
        XCTAssertFalse(Reducer.apply(lateEvent, to: &saved))
    }

    func testSQLiteRoundtripAndSearch() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let store = try Store(path: path)
        var b = Block(); b.body = "中文\n\n' ` $(touch /tmp/no)\n"; b.association = Association(agent: "pi", directory: "/test"); b.association?.sessionID = "Native-ID"
        b.run = Run(snapshot: b.body); try store.save(b)
        XCTAssertEqual(try store.load(), [b])
        XCTAssertTrue(Reducer.matches(b, query: "native-id", archived: false))
        XCTAssertTrue(Reducer.matches(b, query: "中文", archived: false))
        b.archived = true; XCTAssertFalse(Reducer.matches(b, query: "", archived: false))
        XCTAssertTrue(Reducer.matches(b, query: "", archived: true))
        b.deleted = true; XCTAssertFalse(Reducer.matches(b, query: "", archived: true))
        b.deleted = false; XCTAssertEqual(b.association?.sessionID, "Native-ID")
    }
    func event(_ b: Block, _ type: String, sequence: Int, turn: Int = 1, session: String = "real-id") throws -> BridgeEvent {
        let obj: [String: Any] = ["schemaVersion": 1, "eventID": UUID().uuidString, "runID": b.run!.id, "sessionID": session, "turnID": turn, "sequence": sequence, "source": "pi", "type": type, "time": "2026-01-01T00:00:00Z"]
        return try JSONDecoder().decode(BridgeEvent.self, from: JSONSerialization.data(withJSONObject: obj))
    }
    func testEventIdentityOrderingAndDedup() throws {
        var b = Block(); b.association = Association(agent: "pi", directory: "/"); b.run = Run(snapshot: "safe")
        let e = try event(b, "running", sequence: 2)
        XCTAssertTrue(Reducer.apply(e, to: &b)); XCTAssertFalse(Reducer.apply(e, to: &b))
        XCTAssertFalse(Reducer.apply(try event(b, "settled", sequence: 1), to: &b))
        XCTAssertEqual(b.run?.status, "运行中")
        XCTAssertFalse(Reducer.apply(try event(b, "settled", sequence: 3, session: "other"), to: &b))
        XCTAssertNil(b.attention)
        b.run = Run(snapshot: "new"); XCTAssertFalse(Reducer.apply(e, to: &b))
    }
    func testInitialPrefillNeverCompletes() throws {
        var b = Block(); b.association = Association(agent: "pi", directory: "/"); b.run = Run(snapshot: "hello\n")
        XCTAssertTrue(Reducer.apply(try event(b, "prefilled", sequence: 0, turn: 0), to: &b))
        XCTAssertEqual(b.run?.status, "待发送"); XCTAssertNil(b.attention)
        XCTAssertTrue(Reducer.apply(try event(b, "settled", sequence: 1, turn: 0), to: &b)); XCTAssertNil(b.attention)
    }
}
