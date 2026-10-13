import Foundation
@testable import ZeotapSDK

// Test doubles shared by every suite. All of them are lock-protected because the SDK touches them
// from its serial queue while the test thread reads/mutates them between steps.

/// Virtual wall clock. `now` is the epoch-millisecond value `nowMs()` returns; tests pin it or let
/// `FakeScheduler.advance(by:)` move it.
final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(nowMs: Int64) {
        value = nowMs
    }

    /// Current virtual time (settable). Named `now` because `nowMs` is the `Clock` method.
    var now: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    func nowMs() -> Int64 { now }

    func set(nowMs: Int64) { now = nowMs }

    func advance(byMs ms: Int64) { now += ms }
}

/// Deterministic v4-shaped UUIDs: `00000000-0000-4000-8000-000000000001`, `…002`, …
final class SequenceIdGenerator: IdGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    init() {}

    func uuid() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let digits = String(counter)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    }

    /// Number of ids minted so far.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    func reset() {
        lock.lock()
        counter = 0
        lock.unlock()
    }
}

/// Virtual-time `Scheduler`. Timers are registered against `clock.now`; `advance(by:)` fires every
/// timer that falls due inside the window, in due order, ON `queue` (via `queue.sync` when called
/// from another thread), re-arms repeating timers, and finally moves the clock to `start + ms`.
/// Timers scheduled by a firing block that fall inside the same window fire in the same advance
/// (vitest `advanceTimersByTime` semantics).
final class FakeScheduler: Scheduler, @unchecked Sendable {
    let queue: DispatchQueue
    let clock: FakeClock

    private struct Timer {
        let id: Int
        var dueMs: Int64
        let intervalMs: Int64?
        let block: () -> Void
    }

    private let lock = NSLock()
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timers: [Timer] = []
    private var nextId = 0

    init(queue: DispatchQueue, clock: FakeClock) {
        self.queue = queue
        self.clock = clock
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Whether the caller is already executing on `queue`.
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    func async(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    func schedule(after ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        register(dueIn: ms, interval: nil, block)
    }

    func repeating(every ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        register(dueIn: ms, interval: max(1, ms), block)
    }

    /// Timers currently armed (cancelled ones excluded).
    var pendingTimerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timers.count
    }

    /// Due times (absolute epoch ms) of every armed timer, soonest first.
    var pendingDueTimes: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return timers.map(\.dueMs).sorted()
    }

    /// Fire everything due within the next `ms` virtual milliseconds, then set the clock to `start + ms`.
    func advance(by ms: Int64) {
        let start = clock.now
        let end = start + max(0, ms)
        while let timer = popNextDue(upTo: end) {
            if clock.now < timer.dueMs { clock.now = timer.dueMs }
            runOnQueue(timer.block)
        }
        clock.now = end
    }

    /// Barrier: returns once every block already posted to `queue` has run. No-op when called on the queue.
    func runPending() {
        if isOnQueue { return }
        queue.sync {}
    }

    // MARK: - Private

    private func register(dueIn ms: Int64, interval: Int64?, _ block: @escaping () -> Void) -> ScheduledTask {
        lock.lock()
        nextId += 1
        let id = nextId
        timers.append(Timer(id: id, dueMs: clock.now + max(0, ms), intervalMs: interval, block: block))
        lock.unlock()
        return ScheduledTask { [weak self] in self?.cancel(id) }
    }

    private func cancel(_ id: Int) {
        lock.lock()
        timers.removeAll { $0.id == id }
        lock.unlock()
    }

    /// The soonest timer due at or before `end` (ties by registration order); one-shots are removed,
    /// repeating timers are re-armed before the block runs so the block may cancel them.
    private func popNextDue(upTo end: Int64) -> Timer? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = timers.indices.min(by: { (timers[$0].dueMs, timers[$0].id) < (timers[$1].dueMs, timers[$1].id) }),
              timers[index].dueMs <= end else { return nil }
        let timer = timers[index]
        if let interval = timer.intervalMs {
            timers[index].dueMs = timer.dueMs + interval
        } else {
            timers.remove(at: index)
        }
        return timer
    }

    private func runOnQueue(_ block: () -> Void) {
        if isOnQueue {
            block()
        } else {
            queue.sync(execute: block)
        }
    }
}

/// `HTTPClient` that records every request and answers from a script (consumed first) or a default.
/// The completion runs synchronously on the calling thread.
final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request {
        let url: URL
        let headers: [String: String]
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var defaultValue: Result<HTTPResponse, Error> = .success(HTTPResponse(status: 200, body: "{}"))
    private var script: [Result<HTTPResponse, Error>] = []

    init() {}

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Answer used once `scripted` is exhausted.
    var defaultResponse: Result<HTTPResponse, Error> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaultValue
        }
        set {
            lock.lock()
            defaultValue = newValue
            lock.unlock()
        }
    }

    /// Queue of answers consumed in order before `defaultResponse` applies.
    var scripted: [Result<HTTPResponse, Error>] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return script
        }
        set {
            lock.lock()
            script = newValue
            lock.unlock()
        }
    }

    func post(url: URL, headers: [String: String], body: Data, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) {
        lock.lock()
        recorded.append(Request(url: url, headers: headers, body: String(decoding: body, as: UTF8.self)))
        let answer = script.isEmpty ? defaultValue : script.removeFirst()
        lock.unlock()
        completion(answer)
    }

    func reset() {
        lock.lock()
        recorded = []
        script = []
        lock.unlock()
    }
}

/// In-memory `IABTCF_*` defaults. `set(_:notify:)` replaces the data and (by default) fires every
/// observer synchronously on the calling thread, like a CMP SDK writing to `UserDefaults`.
final class FakeTcfDefaults: TcfDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var data: TcData
    private var observers: [Int: () -> Void] = [:]
    private var nextId = 0

    init(_ data: TcData = .empty) {
        self.data = data
    }

    func read() -> TcData {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func observe(_ onChange: @escaping () -> Void) -> ObservationToken {
        lock.lock()
        nextId += 1
        let id = nextId
        observers[id] = onChange
        lock.unlock()
        return ObservationToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    func set(_ data: TcData, notify: Bool = true) {
        lock.lock()
        self.data = data
        let callbacks = notify ? observers.sorted { $0.key < $1.key }.map(\.value) : []
        lock.unlock()
        for callback in callbacks { callback() }
    }

    /// Number of live observations.
    var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }
}

/// `Logger` that keeps every message. `errors` holds the message text; `errorDetails` the paired errors.
final class RecordingLogger: Logger, @unchecked Sendable {
    private let lock = NSLock()
    private var debugMessages: [String] = []
    private var warnMessages: [String] = []
    private var errorMessages: [String] = []
    private var errorValues: [Error?] = []

    init() {}

    var debugs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return debugMessages
    }

    var warns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return warnMessages
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorMessages
    }

    var errorDetails: [Error?] {
        lock.lock()
        defer { lock.unlock() }
        return errorValues
    }

    func debug(_ message: String) {
        lock.lock()
        debugMessages.append(message)
        lock.unlock()
    }

    func warn(_ message: String) {
        lock.lock()
        warnMessages.append(message)
        lock.unlock()
    }

    func error(_ message: String, _ error: Error?) {
        lock.lock()
        errorMessages.append(message)
        errorValues.append(error)
        lock.unlock()
    }
}
