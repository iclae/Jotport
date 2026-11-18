import XCTest
@testable import JotportCore
final class CoreTests: XCTestCase {
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
