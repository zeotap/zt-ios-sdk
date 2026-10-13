import Foundation
import XCTest
@testable import ZeotapSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `Scheduler` for transport tests: a `FakeScheduler` (virtual time, blocks on `queue`) that also
/// RECORDS every `schedule(after:)` delay — the backoff sequence the transport vectors pin
/// (`delaysMs`). `fireNext()` jumps virtual time to the soonest armed timer and fires it.
final class RecordingScheduler: Scheduler, @unchecked Sendable {
    let inner: FakeScheduler
    private let lock = NSLock()
    private var recorded: [Int64] = []

    init(queue: DispatchQueue, clock: FakeClock) {
        inner = FakeScheduler(queue: queue, clock: clock)
    }

    var queue: DispatchQueue { inner.queue }
    var clock: FakeClock { inner.clock }
    var isOnQueue: Bool { inner.isOnQueue }

    /// Every one-shot delay requested so far, in order.
    var delays: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func async(_ block: @escaping () -> Void) {
        inner.async(block)
    }

    func schedule(after ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        lock.lock()
        recorded.append(ms)
        lock.unlock()
        return inner.schedule(after: ms, block)
    }

    func repeating(every ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        inner.repeating(every: ms, block)
    }

    func advance(by ms: Int64) {
        inner.advance(by: ms)
    }

    /// Barrier: every block already posted to `queue` has run when this returns.
    func runPending() {
        inner.runPending()
    }

    /// Advance virtual time to the soonest armed timer and fire it. `false` when nothing is armed.
    @discardableResult
    func fireNext() -> Bool {
        guard let due = inner.pendingDueTimes.first else { return false }
        inner.advance(by: max(0, due - clock.now))
        return true
    }
}

/// Runs `Transport.send` the way the engine does — on the core queue — then drives the scheduler
/// (posted hops, then each armed backoff timer in turn) until the completion fires. Returns `nil`
/// when the transport never completed, which is itself a test failure.
func sendAndDrive(_ transport: Transport, payloads: [String], scheduler: RecordingScheduler, maxTimers: Int = 16) -> SendOutcome? {
    let box = OutcomeBox()
    scheduler.queue.sync {
        transport.send(payloads) { outcome in
            box.set(outcome, onQueue: scheduler.isOnQueue)
        }
    }
    scheduler.runPending()
    var fired = 0
    while box.get() == nil, fired < maxTimers, scheduler.fireNext() {
        fired += 1
        scheduler.runPending()
    }
    return box.get()
}

/// Thread-safe holder for the single `SendOutcome` a `send` produces, plus where it was delivered.
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: SendOutcome?
    private var deliveredOnQueue = false
    private var deliveries = 0

    func set(_ value: SendOutcome, onQueue: Bool) {
        lock.lock()
        outcome = value
        deliveredOnQueue = onQueue
        deliveries += 1
        lock.unlock()
    }

    func get() -> SendOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// Whether the completion ran on the scheduler's queue.
    var wasDeliveredOnQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deliveredOnQueue
    }

    /// How many times the completion fired (must be exactly one).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }
}

/// Deterministic connection failure for scripted HTTP clients (a `URLError`'s description differs
/// between Darwin and swift-corelibs-foundation, so tests that pin the text use this instead).
struct FakeNetworkError: LocalizedError, Equatable {
    let message: String

    init(_ message: String = "network") {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Scripted-response helpers matching the Android `ScriptedHttpClient` conventions: an `Int` status
/// answers with body `{}`, `"network"` is a connection failure.
enum ScriptedResponses {
    static func status(_ code: Int, body: String = "{}") -> Result<HTTPResponse, Error> {
        .success(HTTPResponse(status: code, body: body))
    }

    static func network(_ message: String = "network") -> Result<HTTPResponse, Error> {
        .failure(FakeNetworkError(message))
    }

    /// Vector `responses` (`[500, "network", 200]`) → scripted results; `nil` on an unknown entry.
    static func fromVector(_ responses: [JSONValue]) -> [Result<HTTPResponse, Error>]? {
        var out: [Result<HTTPResponse, Error>] = []
        for entry in responses {
            if let code = entry.intValue {
                out.append(status(Int(code)))
            } else if entry.stringValue == "network" {
                out.append(.failure(URLError(.notConnectedToInternet)))
            } else {
                return nil
            }
        }
        return out
    }
}
