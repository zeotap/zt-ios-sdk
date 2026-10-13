import XCTest
@testable import ZeotapSDK

/// Mirrors `sdk/js/src/queue.test.ts` (FIFO, count, drop-oldest, clear) plus the mobile
/// reservation semantics shared with `SQLiteEventQueue` (reserve / ack / release / releaseAll,
/// byte budget, dedupe by messageId, prune).
final class InMemoryEventQueueTests: XCTestCase {
    private var clock = FakeClock(nowMs: fixedNowMs)

    override func setUp() {
        super.setUp()
        clock = FakeClock(nowMs: fixedNowMs)
    }

    private func queue(maxSize: Int = 500) -> InMemoryEventQueue {
        InMemoryEventQueue(maxSize: maxSize, clock: clock)
    }

    /// reserve-everything + ack — the web `flush()`.
    private func drain(_ q: EventQueue, batchId: String = "drain") throws -> [String] {
        let rows = try q.reserve(batchId: batchId, maxBytes: Int.max)
        try q.ack(batchId: batchId)
        return rows.map(\.messageId)
    }

    // MARK: queue.test.ts

    func testEnqueueIncreasesCount() throws {
        let q = queue()
        XCTAssertEqual(try q.count(), 0)
        try q.enqueue(messageId: "a", payload: "{\"messageId\":\"a\"}")
        XCTAssertEqual(try q.count(), 1)
        try q.enqueue(messageId: "b", payload: "{\"messageId\":\"b\"}")
        XCTAssertEqual(try q.count(), 2)
    }

    func testMultipleEnqueuesMaintainFIFOOrder() throws {
        let q = queue()
        try q.enqueue(messageId: "first", payload: "1")
        try q.enqueue(messageId: "second", payload: "2")
        try q.enqueue(messageId: "third", payload: "3")
        XCTAssertEqual(try drain(q), ["first", "second", "third"])
    }

    func testReserveThenAckReturnsAllItemsAndEmptiesTheQueue() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        let rows = try q.reserve(batchId: "batch", maxBytes: Int.max)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.payload), ["1", "2"])
        XCTAssertEqual(rows.map(\.messageId), ["a", "b"])
        try q.ack(batchId: "batch")
        XCTAssertEqual(try q.count(), 0)
    }

    func testReserveOnEmptyQueueReturnsEmptyArray() throws {
        XCTAssertEqual(try queue().reserve(batchId: "b", maxBytes: Int.max), [])
    }

    func testClearResetsCountToZero() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.clear()
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(try q.reserve(batchId: "b", maxBytes: Int.max), [])
    }

    func testDropsTheOldestItemWhenMaxSizeIsReached() throws {
        let q = queue(maxSize: 3)
        try q.enqueue(messageId: "1", payload: "1")
        try q.enqueue(messageId: "2", payload: "2")
        try q.enqueue(messageId: "3", payload: "3")
        try q.enqueue(messageId: "4", payload: "4")
        XCTAssertEqual(try q.count(), 3)
        XCTAssertEqual(try drain(q), ["2", "3", "4"])
    }

    func testRespectsCustomMaxSize() throws {
        let q = queue(maxSize: 2)
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "c", payload: "3")
        XCTAssertEqual(try q.count(), 2)
        XCTAssertEqual(try drain(q), ["b", "c"])
    }

    func testDefaultMaxQueueSizeMatchesTheWebSDK() throws {
        // queue.ts DEFAULT_MAX_QUEUE_SIZE = 500 → Configuration.maxQueueSize default.
        XCTAssertEqual(Configuration(apiHost: "https://ingest.example").maxQueueSize, 500)
        let q = queue(maxSize: 500)
        for i in 0..<501 { try q.enqueue(messageId: "m\(i)", payload: "\(i)") }
        XCTAssertEqual(try q.count(), 500)
        XCTAssertEqual(try q.reserve(batchId: "x", maxBytes: Int.max).first?.messageId, "m1")
    }

    // MARK: Reservation semantics

    func testReservedRowsAreInvisibleToLaterReservesUntilReleased() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        let first = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(first.map(\.messageId), ["a", "b"])
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max), [])
        XCTAssertEqual(try q.count(), 2, "reserved rows still count")

        try q.release(batchId: "x")
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max).map(\.messageId), ["a", "b"])
    }

    func testAckRemovesOnlyTheAckedBatch() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.ack(batchId: "x")
        XCTAssertEqual(try q.count(), 1)
        try q.release(batchId: "y")
        XCTAssertEqual(try drain(q), ["b"])
    }

    func testReleaseOnlyFreesItsOwnBatch() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.release(batchId: "x")
        XCTAssertEqual(try q.reserve(batchId: "z", maxBytes: Int.max).map(\.messageId), ["a"])
    }

    func testAckAndReleaseOfUnknownBatchAreNoOps() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.ack(batchId: "nope")
        try q.release(batchId: "nope")
        XCTAssertEqual(try q.count(), 1)
        XCTAssertEqual(try drain(q), ["a"])
    }

    func testReleaseAllFreesEveryReservation() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.releaseAll()
        XCTAssertEqual(try q.reserve(batchId: "z", maxBytes: Int.max).map(\.messageId), ["a", "b"])
    }

    func testReleaseAllOnEmptyQueueIsFine() throws {
        let q = queue()
        try q.releaseAll()
        XCTAssertEqual(try q.count(), 0)
    }

    // MARK: Byte budget

    func testReserveRespectsTheByteBudgetAndAlwaysTakesAtLeastOne() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: String(repeating: "x", count: 10))
        try q.enqueue(messageId: "b", payload: String(repeating: "x", count: 10))
        try q.enqueue(messageId: "c", payload: String(repeating: "x", count: 10))
        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 20).map(\.messageId), ["a", "b"])
        // Oversized single row is still taken so the queue can never wedge.
        XCTAssertEqual(try q.reserve(batchId: "2", maxBytes: 5).map(\.messageId), ["c"])
        XCTAssertEqual(try q.reserve(batchId: "3", maxBytes: 5), [])
    }

    func testByteBudgetSplitsBatches() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "b", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "c", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "d", payload: String(repeating: "x", count: 1000))

        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 250).map(\.messageId), ["a", "b"])
        XCTAssertEqual(try q.reserve(batchId: "2", maxBytes: 250).map(\.messageId), ["c"])
        XCTAssertEqual(try q.reserve(batchId: "3", maxBytes: 250).map(\.messageId), ["d"])
        XCTAssertEqual(try q.reserve(batchId: "4", maxBytes: 250), [])
    }

    func testByteBudgetCountsUTF8BytesNotCharacters() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "ééééé") // 5 chars, 10 bytes
        try q.enqueue(messageId: "b", payload: "b")
        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 10).map(\.messageId), ["a"])
        XCTAssertEqual(try q.reserve(batchId: "2", maxBytes: 10).map(\.messageId), ["b"])
    }

    func testBudgetBoundaryIsInclusive() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "12345")
        try q.enqueue(messageId: "b", payload: "12345")
        try q.enqueue(messageId: "c", payload: "1")
        // 5 + 5 == 10 fits; adding 1 more exceeds.
        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 10).map(\.messageId), ["a", "b"])
    }

    func testReserveMarksExactlyTheReturnedRows() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "first", maxBytes: Int.max) // a, b in flight
        try q.enqueue(messageId: "c", payload: "3")
        try q.enqueue(messageId: "d", payload: String(repeating: "x", count: 50))
        // The budget admits c only; d stays unreserved even though its id is higher.
        XCTAssertEqual(try q.reserve(batchId: "second", maxBytes: 10).map(\.messageId), ["c"])
        XCTAssertEqual(try q.reserve(batchId: "third", maxBytes: Int.max).map(\.messageId), ["d"])
        try q.ack(batchId: "first")
        try q.ack(batchId: "second")
        try q.ack(batchId: "third")
        XCTAssertEqual(try q.count(), 0)
    }

    // MARK: Dedupe, drop-oldest, ids

    func testReEnqueueingAMessageIdReplacesTheRowAndMovesItToTheTail() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "a", payload: "1-again")
        XCTAssertEqual(try q.count(), 2)
        let rows = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(rows.map(\.messageId), ["b", "a"])
        XCTAssertEqual(rows.last?.payload, "1-again")
    }

    func testReEnqueueingAReservedMessageIdReplacesItAndClearsTheReservation() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "a", payload: "1-again")
        XCTAssertEqual(try q.count(), 1)
        // The replaced row is a fresh, unreserved row; the old reservation has nothing left.
        try q.ack(batchId: "x")
        XCTAssertEqual(try q.count(), 1)
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max).map(\.payload), ["1-again"])
    }

    func testDropOldestCountsReservedRows() throws {
        let q = queue(maxSize: 2)
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "c", payload: "3")
        XCTAssertEqual(try q.count(), 2)
        try q.ack(batchId: "x") // "a" was already evicted; ack is a no-op
        XCTAssertEqual(try drain(q), ["b", "c"])
    }

    func testIdsAreMonotonicallyIncreasing() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        let rows = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(rows.count, 2)
        XCTAssertLessThan(rows[0].id, rows[1].id)
        try q.ack(batchId: "x")
        try q.enqueue(messageId: "c", payload: "3")
        XCTAssertGreaterThan(try XCTUnwrap(q.reserve(batchId: "y", maxBytes: Int.max).first).id, rows[1].id, "ids are never reused")
    }

    func testPayloadsRoundTripUnchanged() throws {
        let q = queue()
        let payload = "{\"event\":\"O'Reilly \\\"quoted\\\" — ünïcödé 🎉\"}"
        try q.enqueue(messageId: "a", payload: payload)
        XCTAssertEqual(try q.reserve(batchId: "x", maxBytes: Int.max).map(\.payload), [payload])
    }

    // MARK: Prune

    func testPruneRemovesOnlyRowsCreatedBeforeTheCutoff() throws {
        let q = queue()
        try q.enqueue(messageId: "old", payload: "1")
        clock.advance(byMs: 1_000)
        try q.enqueue(messageId: "mid", payload: "2")
        clock.advance(byMs: 1_000)
        try q.enqueue(messageId: "new", payload: "3")

        // Strictly older than the "mid" timestamp → only "old".
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1_000), 1)
        XCTAssertEqual(try q.count(), 2)
        XCTAssertEqual(try drain(q), ["mid", "new"])
    }

    func testPruneIsStrictAndReturnsZeroWhenNothingQualifies() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs), 0, "created_at == cutoff is kept")
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs - 1), 0)
        XCTAssertEqual(try q.count(), 1)
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1), 1)
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(try q.prune(olderThanMs: Int64.max), 0)
    }

    func testPruneRemovesReservedRowsToo() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1), 1)
        XCTAssertEqual(try q.count(), 0)
    }

    func testCloseIsANoOpAndTheQueueStaysUsable() throws {
        let q = queue()
        try q.enqueue(messageId: "a", payload: "1")
        q.close()
        XCTAssertEqual(try q.count(), 1)
    }
}
