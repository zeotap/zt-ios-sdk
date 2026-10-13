import XCTest
@testable import ZeotapSDK

/// `SQLiteEventQueue` on a temp-directory database: the `InMemoryEventQueue` semantics (FIFO,
/// drop-oldest incl. reserved rows, reserve/ack/release, byte budget, dedupe, prune) plus what
/// only a durable queue has — persistence across instances, `releaseAll` after a crash, hostile
/// input bound rather than interpolated, and a garbage file surfacing as `ZeotapError.storage`.
final class SQLiteEventQueueTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory
    private var clock = FakeClock(nowMs: fixedNowMs)
    private var open: [SQLiteEventQueue] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = FakeClock(nowMs: fixedNowMs)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeotap-sdk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        open.forEach { $0.close() }
        open.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var path: String { directory.appendingPathComponent("sdk_events.db").path }

    private func queue(maxSize: Int = 500, path: String? = nil) throws -> SQLiteEventQueue {
        let q = try SQLiteEventQueue(path: path ?? self.path, maxSize: maxSize, clock: clock)
        open.append(q)
        return q
    }

    private func drain(_ q: EventQueue, batchId: String = "drain") throws -> [String] {
        let rows = try q.reserve(batchId: batchId, maxBytes: Int.max)
        try q.ack(batchId: batchId)
        return rows.map(\.messageId)
    }

    // MARK: Basics (queue.test.ts)

    func testEnqueueIncreasesCountAndKeepsFIFOOrder() throws {
        let q = try queue()
        XCTAssertEqual(try q.count(), 0)
        try q.enqueue(messageId: "first", payload: "{\"messageId\":\"first\"}")
        try q.enqueue(messageId: "second", payload: "{\"messageId\":\"second\"}")
        try q.enqueue(messageId: "third", payload: "{\"messageId\":\"third\"}")
        XCTAssertEqual(try q.count(), 3)
        let rows = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(rows.map(\.messageId), ["first", "second", "third"])
        XCTAssertEqual(rows.map(\.payload), ["{\"messageId\":\"first\"}", "{\"messageId\":\"second\"}", "{\"messageId\":\"third\"}"])
        XCTAssertLessThan(rows[0].id, rows[1].id)
        XCTAssertLessThan(rows[1].id, rows[2].id)
    }

    func testAckDeletesTheBatchAndClearEmptiesEverything() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.ack(batchId: "x")
        XCTAssertEqual(try q.count(), 0)

        try q.enqueue(messageId: "c", payload: "3")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.enqueue(messageId: "d", payload: "4")
        try q.clear()
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(try q.reserve(batchId: "z", maxBytes: Int.max), [])
    }

    func testReserveOnEmptyQueueReturnsEmpty() throws {
        XCTAssertEqual(try queue().reserve(batchId: "b", maxBytes: Int.max), [])
    }

    func testReservedRowsAreHiddenUntilReleased() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        XCTAssertEqual(try q.reserve(batchId: "x", maxBytes: Int.max).count, 2)
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max), [])
        XCTAssertEqual(try q.count(), 2)
        try q.release(batchId: "x")
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max).map(\.messageId), ["a", "b"])
    }

    func testReleaseOnlyFreesItsOwnBatch() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.release(batchId: "x")
        XCTAssertEqual(try q.reserve(batchId: "z", maxBytes: Int.max).map(\.messageId), ["a"])
    }

    func testAckRemovesOnlyTheAckedBatch() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.ack(batchId: "x")
        XCTAssertEqual(try q.count(), 1)
        try q.release(batchId: "y")
        XCTAssertEqual(try drain(q), ["b"])
    }

    func testReleaseAllFreesEveryReservation() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "y", maxBytes: Int.max)
        try q.releaseAll()
        XCTAssertEqual(try q.reserve(batchId: "z", maxBytes: Int.max).map(\.messageId), ["a", "b"])
    }

    // MARK: Drop-oldest

    func testDropsTheOldestRowsBeyondMaxSizeIncludingReservedOnes() throws {
        let q = try queue(maxSize: 3)
        try q.enqueue(messageId: "1", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max) // "1" is in flight
        try q.enqueue(messageId: "2", payload: "2")
        try q.enqueue(messageId: "3", payload: "3")
        try q.enqueue(messageId: "4", payload: "4")
        XCTAssertEqual(try q.count(), 3)
        try q.ack(batchId: "x") // nothing left to ack
        XCTAssertEqual(try drain(q), ["2", "3", "4"])
    }

    func testRespectsCustomMaxSize() throws {
        let q = try queue(maxSize: 2)
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "c", payload: "3")
        XCTAssertEqual(try q.count(), 2)
        XCTAssertEqual(try drain(q), ["b", "c"])
    }

    // MARK: Durability

    func testRowsPersistAcrossANewInstanceOnTheSamePath() throws {
        let first = try queue()
        try first.enqueue(messageId: "a", payload: "1")
        try first.enqueue(messageId: "b", payload: "2")
        first.close()

        let second = try queue()
        XCTAssertEqual(try second.count(), 2)
        XCTAssertEqual(try drain(second), ["a", "b"])
    }

    func testIdsKeepIncreasingAcrossInstances() throws {
        let first = try queue()
        try first.enqueue(messageId: "a", payload: "1")
        let firstId = try XCTUnwrap(first.reserve(batchId: "x", maxBytes: Int.max).first).id
        try first.ack(batchId: "x")
        first.close()

        let second = try queue()
        try second.enqueue(messageId: "b", payload: "2")
        let secondId = try XCTUnwrap(second.reserve(batchId: "y", maxBytes: Int.max).first).id
        XCTAssertGreaterThan(secondId, firstId, "AUTOINCREMENT never reuses an id")
    }

    func testReleaseAllAfterACrashMakesInFlightRowsAvailableAgain() throws {
        let crashed = try queue()
        try crashed.enqueue(messageId: "a", payload: "1")
        try crashed.enqueue(messageId: "b", payload: "2")
        _ = try crashed.reserve(batchId: "in-flight", maxBytes: Int.max)
        crashed.close() // process died mid-send: rows still carry batch_id

        let restarted = try queue()
        XCTAssertEqual(try restarted.count(), 2)
        XCTAssertEqual(try restarted.reserve(batchId: "x", maxBytes: Int.max), [], "still reserved by the dead process")
        try restarted.releaseAll()
        XCTAssertEqual(try restarted.reserve(batchId: "x", maxBytes: Int.max).map(\.messageId), ["a", "b"])
    }

    func testReopeningKeepsTheSchemaVersion() throws {
        let first = try queue()
        try first.enqueue(messageId: "a", payload: "1")
        first.close()
        // A second open runs the migration guard (user_version already current) and must not
        // recreate or wipe the table.
        let second = try queue()
        XCTAssertEqual(try second.count(), 1)
        second.close()
        let third = try queue()
        XCTAssertEqual(try drain(third), ["a"])
    }

    func testCreatesMissingParentDirectories() throws {
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true).appendingPathComponent("events.db").path
        let q = try queue(path: nested)
        try q.enqueue(messageId: "a", payload: "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
        XCTAssertEqual(try q.count(), 1)
    }

    func testTwoDatabasesAreIndependent() throws {
        let a = try queue(path: directory.appendingPathComponent("a.db").path)
        let b = try queue(path: directory.appendingPathComponent("b.db").path)
        try a.enqueue(messageId: "only-a", payload: "1")
        XCTAssertEqual(try a.count(), 1)
        XCTAssertEqual(try b.count(), 0)
    }

    // MARK: Byte budget

    func testByteBudgetSplitsBatchesAndAlwaysTakesAtLeastOne() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "b", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "c", payload: String(repeating: "x", count: 100))
        try q.enqueue(messageId: "d", payload: String(repeating: "x", count: 1000))

        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 250).map(\.messageId), ["a", "b"])
        XCTAssertEqual(try q.reserve(batchId: "2", maxBytes: 250).map(\.messageId), ["c"])
        XCTAssertEqual(try q.reserve(batchId: "3", maxBytes: 250).map(\.messageId), ["d"])
        XCTAssertEqual(try q.reserve(batchId: "4", maxBytes: 250), [])
    }

    func testByteBudgetCountsUTF8Bytes() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "ééééé") // 10 bytes
        try q.enqueue(messageId: "b", payload: "b")
        XCTAssertEqual(try q.reserve(batchId: "1", maxBytes: 10).map(\.messageId), ["a"])
        XCTAssertEqual(try q.reserve(batchId: "2", maxBytes: 10).map(\.messageId), ["b"])
    }

    func testReserveMarksExactlyTheReturnedRows() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        _ = try q.reserve(batchId: "first", maxBytes: Int.max) // a, b in flight
        try q.enqueue(messageId: "c", payload: "3")
        try q.enqueue(messageId: "d", payload: String(repeating: "x", count: 50))
        // The budget admits c only; d must remain unreserved even though its id is higher.
        XCTAssertEqual(try q.reserve(batchId: "second", maxBytes: 10).map(\.messageId), ["c"])
        XCTAssertEqual(try q.reserve(batchId: "third", maxBytes: Int.max).map(\.messageId), ["d"])
        try q.ack(batchId: "first")
        try q.ack(batchId: "second")
        try q.ack(batchId: "third")
        XCTAssertEqual(try q.count(), 0)
    }

    func testReserveWithInterleavedReservationsOnlyTakesUnreservedRows() throws {
        // Unreserved rows with ids both below and above a reserved row: the range UPDATE must not
        // touch the reserved row, and must reserve every row it returned.
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "c", payload: "3")
        let middle = try q.reserve(batchId: "mid", maxBytes: 1) // takes "a" only (budget 1, ≥1 rule)
        XCTAssertEqual(middle.map(\.messageId), ["a"])
        try q.enqueue(messageId: "d", payload: "4")
        let rest = try q.reserve(batchId: "rest", maxBytes: Int.max)
        XCTAssertEqual(rest.map(\.messageId), ["b", "c", "d"])
        try q.ack(batchId: "rest")
        XCTAssertEqual(try q.count(), 1)
        try q.release(batchId: "mid")
        XCTAssertEqual(try drain(q), ["a"])
    }

    // MARK: Dedupe

    func testDuplicateMessageIdIsReplacedAndMovesToTheTail() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        try q.enqueue(messageId: "a", payload: "1-again")
        XCTAssertEqual(try q.count(), 2)
        let rows = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(rows.map(\.messageId), ["b", "a"])
        XCTAssertEqual(rows.last?.payload, "1-again")
    }

    func testDuplicateOfAReservedRowReplacesItUnreserved() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        try q.enqueue(messageId: "a", payload: "1-again")
        XCTAssertEqual(try q.count(), 1)
        try q.ack(batchId: "x")
        XCTAssertEqual(try q.count(), 1, "the replacement row is not part of the old batch")
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max).map(\.payload), ["1-again"])
    }

    // MARK: Content

    func testPayloadsWithQuotesAndUnicodeRoundTrip() throws {
        let q = try queue()
        let payload = "{\"event\":\"O'Reilly \\\"quoted\\\" — ünïcödé 🎉\"}"
        try q.enqueue(messageId: "a", payload: payload)
        XCTAssertEqual(try q.reserve(batchId: "x", maxBytes: Int.max).map(\.payload), [payload])
    }

    func testHostileMessageIdsAndBatchIdsAreBoundNotInterpolated() throws {
        let q = try queue()
        try q.enqueue(messageId: "a'; DROP TABLE events; --", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        XCTAssertEqual(try q.count(), 2)
        _ = try q.reserve(batchId: "x' OR '1'='1", maxBytes: Int.max)
        try q.release(batchId: "nope")
        XCTAssertEqual(try q.reserve(batchId: "y", maxBytes: Int.max), [])
        try q.ack(batchId: "x' OR '1'='1")
        XCTAssertEqual(try q.count(), 0)
    }

    func testLargePayloadRoundTrips() throws {
        let q = try queue()
        let payload = String(repeating: "0123456789", count: 200_000) // 2 MB
        try q.enqueue(messageId: "big", payload: payload)
        XCTAssertEqual(try q.reserve(batchId: "x", maxBytes: 1).first?.payload, payload)
    }

    // MARK: Prune

    func testPruneRemovesOnlyRowsCreatedBeforeTheCutoff() throws {
        let q = try queue()
        try q.enqueue(messageId: "old", payload: "1")
        clock.advance(byMs: 1_000)
        try q.enqueue(messageId: "mid", payload: "2")
        clock.advance(byMs: 1_000)
        try q.enqueue(messageId: "new", payload: "3")

        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1_000), 1)
        XCTAssertEqual(try q.count(), 2)
        XCTAssertEqual(try drain(q), ["mid", "new"])
    }

    func testPruneIsStrictAndReportsTheCount() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        try q.enqueue(messageId: "b", payload: "2")
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs), 0, "created_at == cutoff is kept")
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1), 2)
        XCTAssertEqual(try q.count(), 0)
        XCTAssertEqual(try q.prune(olderThanMs: Int64.max), 0)
    }

    func testPruneRemovesReservedRowsToo() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        _ = try q.reserve(batchId: "x", maxBytes: Int.max)
        XCTAssertEqual(try q.prune(olderThanMs: fixedNowMs + 1), 1)
        XCTAssertEqual(try q.count(), 0)
    }

    // MARK: Failure modes

    func testGarbageFileThrowsStorageError() throws {
        let garbage = directory.appendingPathComponent("garbage.db").path
        try Data(String(repeating: "this is not a sqlite database\n", count: 64).utf8).write(to: URL(fileURLWithPath: garbage))

        XCTAssertThrowsError(try SQLiteEventQueue(path: garbage, maxSize: 500, clock: clock)) { error in
            guard case let .storage(detail)? = error as? ZeotapError else {
                return XCTFail("expected ZeotapError.storage, got \(error)")
            }
            XCTAssertTrue(detail.hasPrefix("sqlite: "), detail)
            XCTAssertEqual(error.localizedDescription, "[SDK] Storage error: \(detail)")
        }
    }

    func testUnwritableLocationThrowsStorageError() throws {
        // A directory where the database file should be: open must fail, not hang or trap.
        let asDirectory = directory.appendingPathComponent("iam-a-directory.db", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SQLiteEventQueue(path: asDirectory.path, maxSize: 500, clock: clock)) { error in
            guard case .storage? = error as? ZeotapError else { return XCTFail("expected ZeotapError.storage, got \(error)") }
        }
    }

    func testOperationsAfterCloseThrowStorageErrorInsteadOfCrashing() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        q.close()
        q.close() // idempotent

        XCTAssertThrowsError(try q.enqueue(messageId: "b", payload: "2")) { error in
            XCTAssertEqual(error as? ZeotapError, .storage("sqlite: connection is closed"))
        }
        XCTAssertThrowsError(try q.count())
        XCTAssertThrowsError(try q.reserve(batchId: "x", maxBytes: Int.max))
        XCTAssertThrowsError(try q.ack(batchId: "x"))
        XCTAssertThrowsError(try q.release(batchId: "x"))
        XCTAssertThrowsError(try q.releaseAll())
        XCTAssertThrowsError(try q.prune(olderThanMs: 0))
        XCTAssertThrowsError(try q.clear())
    }

    func testCloseFlushesSoTheDataIsReadableByAFreshConnection() throws {
        let q = try queue()
        try q.enqueue(messageId: "a", payload: "1")
        q.close()
        // WAL mode: after close the main file (or its checkpointed WAL) must hold the row.
        let reopened = try queue()
        XCTAssertEqual(try reopened.count(), 1)
    }
}
