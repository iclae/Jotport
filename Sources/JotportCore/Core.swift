import Foundation
import CSQLite

public struct Association: Codable, Equatable {
    public var id = UUID().uuidString
    public var agent: String
    public var sessionID: String?
    public var directory: String
    public var detachedRunID: String?
    public init(agent: String, directory: String) { self.agent = agent; self.directory = directory }
}
public struct TerminalRef: Codable, Equatable {
    public var path: String; public var identity: String; public var version: String
    public var processID: Int32?; public var launchedAt: Date?; public var paneID: String?; public var socketPath: String?; public var terminalKind: String?
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
    public var launchDirectory: String?
    public var association: Association?
    public var history: [Association] = []
    public var run: Run?
    public var recap = ""
    public var recapSource = ""
    public var recapHidden: Bool?
    public var attention: String?
    public var attentionPromoted: String?
    public var attentionTime: String?
    public var seenEvents: Set<String> = []
    public init() {}

    public mutating func clearBinding() {
        guard var association else { return }
        association.detachedRunID = run?.id
        history.append(association)
        launchDirectory = launchDirectory ?? association.directory
        self.association = nil
        run = nil
        recap = ""
        recapSource = ""
        recapHidden = nil
        attention = nil
        attentionPromoted = nil
        attentionTime = nil
        seenEvents.removeAll()
    }
}
public enum Reducer {
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
    public func save(_ blocks: [Block]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for block in blocks { try save(block) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
