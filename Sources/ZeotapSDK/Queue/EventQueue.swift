import Foundation

/// A queued, fully-serialised event. `payload` is the final JSON bytes as a UTF-8 string.
struct QueuedEvent: Equatable, Sendable {
    let id: Int64
    let messageId: String
    let payload: String
}

/// Durable FIFO event queue with reservation semantics (the deliberate mobile divergence from
/// the web SDK's in-memory `Queue`):
///  - `enqueue` appends; when `count` would exceed `maxSize` the OLDEST rows are deleted first
///    (web `queue.ts` drop-oldest, made durable; reserved rows count towards the cap).
///  - `reserve` marks unreserved rows (oldest first, up to `maxBytes` of payload, always at least
///    one) with `batchId` and returns them; a reserved row is invisible to later reserves until
///    `ack`ed (deleted) or `release`d (made available again).
///  - `releaseAll` runs at start-up: rows still reserved belonged to a process that died mid-send
///    and must be re-sent (at-least-once).
/// Used from the SDK's serial queue only.
protocol EventQueue: AnyObject {
    func enqueue(messageId: String, payload: String) throws
    func reserve(batchId: String, maxBytes: Int) throws -> [QueuedEvent]
    func ack(batchId: String) throws
    func release(batchId: String) throws
    func releaseAll() throws
    /// Delete rows older than `olderThanMs` (epoch ms). Returns the number pruned.
    func prune(olderThanMs: Int64) throws -> Int
    func count() throws -> Int
    func clear() throws
    func close()
}
