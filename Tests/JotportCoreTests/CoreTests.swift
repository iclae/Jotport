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
        block.association?.sessionID = "real-id"
        block.run = Run(snapshot: block.body)
        block.attention = "reply"

        block.clearBinding()
        block.clearBinding()
        try store.save(block)

        let saved = try XCTUnwrap(store.load().first)
        XCTAssertEqual(saved.body, "项目笔记")
        XCTAssertEqual(saved.launchDirectory, "/Projects/Original")
        XCTAssertNil(saved.association)
        XCTAssertNil(saved.run)
        XCTAssertNil(saved.attention)
        XCTAssertEqual(saved.history.map(\.sessionID), ["real-id"])
        XCTAssertTrue(Reducer.matches(saved, query: "real-id", archived: false))
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
}
