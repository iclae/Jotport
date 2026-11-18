import Foundation
import CSQLite

public struct Association: Codable, Equatable {
    public var id = UUID().uuidString
    public var agent: String
    public var sessionID: String?
    public var directory: String
    public init(agent: String, directory: String) { self.agent = agent; self.directory = directory }
}
public struct TerminalRef: Codable, Equatable {
    public var path: String; public var identity: String; public var version: String
    public var processID: Int32?; public var launchedAt: Date?; public var paneID: String?
    public init(path: String, identity: String, version: String) { self.path = path; self.identity = identity; self.version = version }
}
public struct Run: Codable, Equatable {
    public var id = UUID().uuidString
    public var requestID = UUID().uuidString
    public var snapshot: String
    public var status = "启动中"
    public var turn = 0
    public var lastSequence = -1
    public var terminal: TerminalRef?
    public var injected = false
    public init(snapshot: String) { self.snapshot = snapshot }
}
public struct Block: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var body = ""
    public var revision = 0
    public var order: Double = 0
    public var pinned = false
    public var archived = false
    public var deleted = false
    public var created = Date()
    public var updated = Date()
    public var association: Association?
    public var history: [Association] = []
    public var run: Run?
    public var recap = ""
    public var recapSource = ""
    public var attention: String?
    public var seenEvents: Set<String> = []
    public init() {}
}
public struct BridgeEvent: Codable {
    public var schemaVersion: Int
    public var eventID: String
    public var runID: String
    public var sessionID: String
    public var turnID: Int
    public var sequence: Int
    public var source: String
    public var type: String
    public var time: String
    public var text: String?
}
public enum Reducer {
    @discardableResult public static func apply(_ e: BridgeEvent, to b: inout Block) -> Bool {
        guard e.schemaVersion == 1, var r = b.run, r.id == e.runID,
              e.sequence > r.lastSequence, e.turnID >= r.turn,
              !b.seenEvents.contains(e.eventID), e.source == b.association?.agent,
              !e.sessionID.isEmpty else { return false }
        guard b.association?.sessionID == nil || b.association?.sessionID == e.sessionID else {
            r.status = "状态未知：终端会话已切换"; b.run = r; return false
        }
        b.association?.sessionID = e.sessionID
        r.lastSequence = e.sequence; r.turn = e.turnID
        b.seenEvents.insert(e.eventID)
        switch e.type {
        case "bound": r.status = "已打开，待粘贴"
        case "prefilled": r.status = "待发送"; r.injected = true
        case "running": r.status = "运行中"
        case "waiting": r.status = "需要输入"; b.attention = e.eventID
        case "settled":
            guard e.turnID > 0 else { b.run = r; return true }
            r.status = "结果待查看"; b.attention = e.eventID
            if let text = e.text, !text.isEmpty { b.recap = String(text.prefix(4000)); b.recapSource = "\(e.sessionID) · 轮次 \(e.turnID) · \(e.time)" }
        case "exited": r.status = "已退出"
        default: r.status = "状态未知"
        }
        b.run = r; return true
    }
    public static func matches(_ b: Block, query: String, archived: Bool) -> Bool {
        guard !b.deleted, archived || !b.archived else { return false }
        let a = ([b.association].compactMap { $0 } + b.history)
        let text = ([b.body, b.recap] + a.flatMap { [$0.agent, $0.directory, $0.sessionID ?? ""] }).joined(separator: "\n")
        return query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
public final class Store {
    private var db: OpaquePointer?
    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS blocks (id TEXT PRIMARY KEY, payload BLOB NOT NULL);")
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError { NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    public func save(_ b: Block) throws {
        let data = try JSONEncoder().encode(b)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO blocks VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, b.id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func load() throws -> [Block] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM blocks", -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        var result: [Block] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            let data = Data(bytes: sqlite3_column_blob(s, 0), count: Int(sqlite3_column_bytes(s, 0)))
            result.append(try JSONDecoder().decode(Block.self, from: data))
        }
        return result
    }
}
