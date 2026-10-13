import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// `sqlite3_bind_text` destructor telling SQLite to copy the bound bytes before the call returns
/// (the Swift string's buffer does not outlive the `withCString` scope).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Durable `EventQueue` over the system SQLite — the deliberate mobile divergence from the web
/// SDK's in-memory queue. One table:
///
/// ```
/// events(id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL UNIQUE,
///        payload TEXT NOT NULL, created_at INTEGER NOT NULL, batch_id TEXT)
/// ```
///
/// `id` is the FIFO order, `message_id` the at-least-once dedupe key, `batch_id` the in-flight
/// reservation (NULL = available). Every value is a bound parameter; nothing is interpolated
/// into SQL. Failures surface as `ZeotapError.storage("sqlite: …")` and are never swallowed —
/// the engine reports them through `SdkListener.onError`.
///
/// Schema versions live in `PRAGMA user_version`; migrations are ADDITIVE ONLY (a future
/// version may add columns/indexes, never drop or rewrite `events`, because its rows are a user's
/// unsent events). Used from the SDK's serial queue only (the connection is opened FULLMUTEX
/// regardless).
final class SQLiteEventQueue: EventQueue {
    static let schemaVersion: Int64 = 1

    private let maxSize: Int
    private let clock: Clock
    private let db: SQLiteDB

    init(path: String, maxSize: Int, clock: Clock) throws {
        self.maxSize = maxSize
        self.clock = clock
        SQLiteEventQueue.ensureParentDirectory(of: path)
        let db = try SQLiteDB(path: path)
        do {
            try db.exec("PRAGMA journal_mode=WAL")
            try db.exec("PRAGMA synchronous=NORMAL")
            try SQLiteEventQueue.migrate(db)
        } catch {
            db.close()
            throw error
        }
        self.db = db
        SQLiteEventQueue.protectFiles(at: path)
    }

    // MARK: - EventQueue

    func enqueue(messageId: String, payload: String) throws {
        try db.transaction {
            // REPLACE deletes the row with the same message_id and inserts a fresh one (new
            // autoincrement id) — a re-enqueue moves to the tail.
            try db.run(
                "INSERT OR REPLACE INTO events (message_id, payload, created_at, batch_id) VALUES (?, ?, ?, NULL)",
                [.text(messageId), .text(payload), .int(clock.nowMs())]
            )
            // Hard cap: drop the OLDEST rows — reserved ones included — beyond maxSize.
            let excess = try db.scalar("SELECT COUNT(*) FROM events") - Int64(maxSize)
            if excess > 0 {
                try db.run("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY id ASC LIMIT ?)", [.int(excess)])
            }
        }
    }

    func reserve(batchId: String, maxBytes: Int) throws -> [QueuedEvent] {
        var taken: [QueuedEvent] = []
        try db.transaction {
            var bytes = 0
            try db.query("SELECT id, message_id, payload FROM events WHERE batch_id IS NULL ORDER BY id ASC") { row in
                let payload = row.text(2)
                let size = payload.utf8.count
                // Always take at least one row so an oversized payload cannot wedge the queue.
                if !taken.isEmpty && bytes + size > maxBytes { return false }
                taken.append(QueuedEvent(id: row.int(0), messageId: row.text(1), payload: payload))
                bytes += size
                return true
            }
            if let last = taken.last {
                // The taken rows are exactly the unreserved rows with id <= the last one read (a
                // prefix in id order, inside this transaction), so a range predicate replaces an
                // IN-list and sidesteps SQLite's bound-variable limit.
                try db.run("UPDATE events SET batch_id = ? WHERE batch_id IS NULL AND id <= ?", [.text(batchId), .int(last.id)])
            }
        }
        return taken
    }

    func ack(batchId: String) throws {
        try db.run("DELETE FROM events WHERE batch_id = ?", [.text(batchId)])
    }

    func release(batchId: String) throws {
        try db.run("UPDATE events SET batch_id = NULL WHERE batch_id = ?", [.text(batchId)])
    }

    func releaseAll() throws {
        try db.run("UPDATE events SET batch_id = NULL WHERE batch_id IS NOT NULL")
    }

    func prune(olderThanMs: Int64) throws -> Int {
        try db.run("DELETE FROM events WHERE created_at < ?", [.int(olderThanMs)])
        return db.changes()
    }

    func count() throws -> Int {
        Int(try db.scalar("SELECT COUNT(*) FROM events"))
    }

    func clear() throws {
        try db.run("DELETE FROM events")
    }

    func close() {
        db.close()
    }

    // MARK: - Schema

    private static func migrate(_ db: SQLiteDB) throws {
        let version = try db.scalar("PRAGMA user_version")
        guard version < schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.exec(
                    """
                    CREATE TABLE IF NOT EXISTS events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        message_id TEXT NOT NULL UNIQUE,
                        payload TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        batch_id TEXT
                    )
                    """
                )
                try db.exec("CREATE INDEX IF NOT EXISTS idx_events_batch_id ON events(batch_id)")
            }
            // PRAGMA does not accept bound parameters; the value is our own integer constant.
            try db.exec("PRAGMA user_version = \(schemaVersion)")
        }
    }

    // MARK: - File hygiene

    private static func ensureParentDirectory(of path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    /// Queued events are unsent user data: keep them out of device backups and, on iOS, encrypted
    /// until first unlock (the SDK may flush from a background launch before the user unlocks).
    private static func protectFiles(at path: String) {
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file
            )
            #endif
            #if canImport(Darwin)
            var url = URL(fileURLWithPath: file)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            #endif
        }
    }
}

// MARK: - Thin SQLite wrapper

/// One SQLite connection: open (READWRITE | CREATE | FULLMUTEX), exec, prepared statements with
/// bound parameters, transactions. Every failure becomes `ZeotapError.storage("sqlite: <errmsg>")`.
private final class SQLiteDB {
    enum Binding {
        case text(String)
        case int(Int64)
    }

    /// Column accessors for the current row of a stepped statement.
    struct Row {
        fileprivate let stmt: OpaquePointer

        func text(_ column: Int32) -> String {
            guard let cString = sqlite3_column_text(stmt, column) else { return "" }
            return String(cString: cString)
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(stmt, column)
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database (code \(rc))"
            sqlite3_close_v2(db)
            throw ZeotapError.storage("sqlite: \(message)")
        }
        handle = opened
    }

    deinit { close() }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    func changes() -> Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    /// Run parameter-less SQL (DDL, PRAGMA, transaction control).
    func exec(_ sql: String) throws {
        let handle = try open()
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure(handle) }
    }

    /// Run one statement with bound parameters, discarding any rows.
    func run(_ sql: String, _ bindings: [Binding] = []) throws {
        try query(sql, bindings) { _ in true }
    }

    /// First column of the first row, as an integer (0 when the statement yields no row).
    func scalar(_ sql: String, _ bindings: [Binding] = []) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, bindings) { row in
            value = row.int(0)
            return false
        }
        return value
    }

    /// Step through the rows; the visitor returns `false` to stop early.
    func query(_ sql: String, _ bindings: [Binding] = [], _ visit: (Row) throws -> Bool) throws {
        let handle = try open()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            sqlite3_finalize(stmt)
            throw failure(handle)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try bind(binding, at: Int32(offset + 1), to: statement, on: handle)
        }
        while true {
            let rc = sqlite3_step(statement)
            switch rc {
            case SQLITE_ROW:
                if try !visit(Row(stmt: statement)) { return }
            case SQLITE_DONE:
                return
            default:
                throw failure(handle)
            }
        }
    }

    /// `BEGIN IMMEDIATE … COMMIT`, rolling back when the body throws.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
        } catch {
            // Best effort: the original error is the one worth reporting.
            try? exec("ROLLBACK")
            throw error
        }
        try exec("COMMIT")
    }

    // MARK: Internals

    private func open() throws -> OpaquePointer {
        guard let handle else { throw ZeotapError.storage("sqlite: connection is closed") }
        return handle
    }

    private func bind(_ binding: Binding, at index: Int32, to statement: OpaquePointer, on handle: OpaquePointer) throws {
        let rc: Int32
        switch binding {
        case let .text(value):
            rc = value.withCString { cString in
                sqlite3_bind_text(statement, index, cString, Int32(value.utf8.count), SQLITE_TRANSIENT)
            }
        case let .int(value):
            rc = sqlite3_bind_int64(statement, index, value)
        }
        guard rc == SQLITE_OK else { throw failure(handle) }
    }

    private func failure(_ handle: OpaquePointer) -> ZeotapError {
        .storage("sqlite: \(String(cString: sqlite3_errmsg(handle)))")
    }
}
