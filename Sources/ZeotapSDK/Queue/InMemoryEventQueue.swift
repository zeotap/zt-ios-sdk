import Foundation

/// Non-durable `EventQueue` with exactly the semantics of `SQLiteEventQueue` (web `queue.ts`
/// drop-oldest plus reservation) — used by client tests and as the fallback when the SQLite
/// store cannot be opened. Used from the SDK's serial queue only.
final class InMemoryEventQueue: EventQueue {
    private struct Row {
        let id: Int64
        let messageId: String
        let payload: String
        let createdAt: Int64
        var batchId: String?
    }

    private let maxSize: Int
    private let clock: Clock
    private var rows: [Row] = []
    private var nextId: Int64 = 1

    init(maxSize: Int, clock: Clock) {
        self.maxSize = maxSize
        self.clock = clock
    }

    func enqueue(messageId: String, payload: String) throws {
        // INSERT OR REPLACE: a re-enqueued messageId moves to the tail with a new id.
        rows.removeAll { $0.messageId == messageId }
        rows.append(Row(id: nextId, messageId: messageId, payload: payload, createdAt: clock.nowMs(), batchId: nil))
        nextId += 1
        // Drop-oldest is a hard cap: reserved rows count and are evicted too.
        let excess = rows.count - maxSize
        if excess > 0 { rows.removeFirst(excess) }
    }

    func reserve(batchId: String, maxBytes: Int) throws -> [QueuedEvent] {
        var taken: [QueuedEvent] = []
        var bytes = 0
        for index in rows.indices where rows[index].batchId == nil {
            let size = rows[index].payload.utf8.count
            // Always take at least one row so an oversized payload cannot wedge the queue.
            if !taken.isEmpty && bytes + size > maxBytes { break }
            rows[index].batchId = batchId
            taken.append(QueuedEvent(id: rows[index].id, messageId: rows[index].messageId, payload: rows[index].payload))
            bytes += size
        }
        return taken
    }

    func ack(batchId: String) throws {
        rows.removeAll { $0.batchId == batchId }
    }

    func release(batchId: String) throws {
        for index in rows.indices where rows[index].batchId == batchId { rows[index].batchId = nil }
    }

    func releaseAll() throws {
        for index in rows.indices { rows[index].batchId = nil }
    }

    func prune(olderThanMs: Int64) throws -> Int {
        let before = rows.count
        rows.removeAll { $0.createdAt < olderThanMs }
        return before - rows.count
    }

    func count() throws -> Int { rows.count }

    func clear() throws {
        rows.removeAll()
    }

    func close() {}
}
