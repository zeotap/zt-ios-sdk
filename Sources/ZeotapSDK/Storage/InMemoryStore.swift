import Foundation

/// Lock-protected in-memory `KeyValueStore`. The Keychain fallback on platforms without
/// `Security`, and the test double everywhere: `writes` / `removes` count `set` / `remove` calls
/// (the conformance vectors pin write deltas) and `snapshot()` returns the current contents.
final class InMemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var writeCount = 0
    private var removeCount = 0

    init(_ initial: [String: String] = [:]) {
        values = initial
    }

    /// Number of `set` calls so far.
    var writes: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCount
    }

    /// Number of `remove` calls so far (including removes of absent keys).
    var removes: Int {
        lock.lock()
        defer { lock.unlock() }
        return removeCount
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        writeCount += 1
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
        removeCount += 1
    }

    /// Copy of the current contents.
    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// Zero the `writes` / `removes` counters (contents are kept).
    func resetCounters() {
        lock.lock()
        defer { lock.unlock() }
        writeCount = 0
        removeCount = 0
    }
}
