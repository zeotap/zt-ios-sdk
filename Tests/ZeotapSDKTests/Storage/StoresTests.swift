import XCTest
@testable import ZeotapSDK

/// The three `KeyValueStore` implementations: the in-memory test double (counters, snapshot), the
/// default `UserDefaults` suite store, and the Keychain store's shape / off-Apple fallback.
final class StoresTests: XCTestCase {
    // MARK: InMemoryStore

    func testInMemoryStoreRoundTripAndInitialContents() {
        let store = InMemoryStore(["a": "1"])
        XCTAssertEqual(store.get("a"), "1")
        XCTAssertNil(store.get("missing"))
        store.set("b", "2")
        XCTAssertEqual(store.get("b"), "2")
        store.set("b", "3")
        XCTAssertEqual(store.get("b"), "3")
        store.remove("a")
        XCTAssertNil(store.get("a"))
    }

    func testInMemoryStoreCountsWritesAndRemoves() {
        let store = InMemoryStore(["seed": "x"])
        XCTAssertEqual(store.writes, 0, "initial contents are not writes")
        XCTAssertEqual(store.removes, 0)
        store.set("k", "v")
        store.set("k", "v2")
        XCTAssertEqual(store.writes, 2)
        store.remove("k")
        store.remove("absent")
        XCTAssertEqual(store.removes, 2, "removing an absent key still counts")
        store.resetCounters()
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.removes, 0)
        XCTAssertEqual(store.get("seed"), "x", "resetCounters keeps the contents")
    }

    func testInMemoryStoreSnapshotIsACopy() {
        let store = InMemoryStore()
        store.set("a", "1")
        let snapshot = store.snapshot()
        store.set("b", "2")
        XCTAssertEqual(snapshot, ["a": "1"])
        XCTAssertEqual(store.snapshot(), ["a": "1", "b": "2"])
    }

    func testInMemoryStoreIsThreadSafe() {
        let store = InMemoryStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            store.set("k\(i % 10)", "\(i)")
            _ = store.get("k\(i % 7)")
            if i % 5 == 0 { store.remove("k\(i % 3)") }
        }
        XCTAssertEqual(store.writes, 200)
        XCTAssertEqual(store.removes, 40)
    }

    // MARK: UserDefaultsStore

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "com.zeotap.sdk.tests.store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testUserDefaultsStoreRoundTripsThroughTheInjectedSuite() throws {
        let defaults = try isolatedDefaults()
        let store = UserDefaultsStore(defaults: defaults)
        XCTAssertNil(store.get("zeotap_anonymous_id"))
        store.set("zeotap_anonymous_id", "anon-1")
        XCTAssertEqual(store.get("zeotap_anonymous_id"), "anon-1")
        XCTAssertEqual(defaults.string(forKey: "zeotap_anonymous_id"), "anon-1", "stored as a plain string")
        store.set("zeotap_anonymous_id", "anon-2")
        XCTAssertEqual(store.get("zeotap_anonymous_id"), "anon-2")
        store.remove("zeotap_anonymous_id")
        XCTAssertNil(store.get("zeotap_anonymous_id"))
        XCTAssertNil(defaults.object(forKey: "zeotap_anonymous_id"))
    }

    func testUserDefaultsStoreReadsForeignNonStringValuesAsAbsent() throws {
        let defaults = try isolatedDefaults()
        defaults.set(42, forKey: "zeotap_user_id")
        defaults.set(["a"], forKey: "zeotap_consent")
        let store = UserDefaultsStore(defaults: defaults)
        XCTAssertNil(store.get("zeotap_user_id"))
        XCTAssertNil(store.get("zeotap_consent"))
    }

    func testUserDefaultsStorePreservesUnicodeAndJsonPayloads() throws {
        let store = UserDefaultsStore(defaults: try isolatedDefaults())
        let record = "{\"v\":1,\"signals\":{\"track\":true},\"name\":\"jürgen 🙂\"}"
        store.set("zeotap_consent", record)
        XCTAssertEqual(store.get("zeotap_consent"), record)
    }

    func testUserDefaultsStoreSuiteNameInitialiserIsUsable() {
        let suiteName = "com.zeotap.sdk.tests.suite.\(UUID().uuidString)"
        let store = UserDefaultsStore(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        store.set("k", "v")
        XCTAssertEqual(store.get("k"), "v")
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.string(forKey: "k"), "v")
        XCTAssertEqual(UserDefaultsStore.defaultSuiteName, "com.zeotap.sdk")
    }

    // MARK: KeychainStore

    func testKeychainStoreServiceAndAccessGroup() {
        let store = KeychainStore(namespace: "zeotap")
        XCTAssertEqual(store.service, "com.zeotap.sdk.zeotap")
        XCTAssertNil(store.accessGroup)
        let shared = KeychainStore(namespace: "acme", accessGroup: "TEAM.com.acme.shared")
        XCTAssertEqual(shared.service, "com.zeotap.sdk.acme")
        XCTAssertEqual(shared.accessGroup, "TEAM.com.acme.shared")
    }

    #if !canImport(Security)
    func testKeychainStoreFallsBackToMemoryWithoutSecurityFramework() {
        let store = KeychainStore(namespace: "zeotap")
        XCTAssertNil(store.get("k"))
        store.set("k", "v")
        XCTAssertEqual(store.get("k"), "v")
        store.set("k", "v2")
        XCTAssertEqual(store.get("k"), "v2")
        store.remove("k")
        XCTAssertNil(store.get("k"))
        store.remove("k") // absent → no crash

        // Instances do not share state (like separate Keychain services would not share items).
        let other = KeychainStore(namespace: "zeotap")
        store.set("k", "v3")
        XCTAssertNil(other.get("k"))
    }
    #endif
}
