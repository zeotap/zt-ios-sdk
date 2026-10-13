import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/identity.test.ts` over an `InMemoryStore` and a deterministic id generator.
final class IdentityStoreTests: XCTestCase {
    private func make(_ namespace: String = "test", storage: InMemoryStore = InMemoryStore(), ids: SequenceIdGenerator = SequenceIdGenerator()) -> (IdentityStore, InMemoryStore, SequenceIdGenerator) {
        (IdentityStore(keys: Keys(namespace: namespace), storage: storage, ids: ids), storage, ids)
    }

    // MARK: constructor

    func testGeneratesAnAnonymousIdAndPersistsIt() {
        let (identity, storage, _) = make()
        let anon = identity.anonymousId()
        XCTAssertEqual(anon, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(storage.get("test_anonymous_id"), anon)
        XCTAssertEqual(storage.writes, 1)
    }

    func testLoadsAnExistingAnonymousId() {
        let storage = InMemoryStore(["test_anonymous_id": "existing-anon-123"])
        let (identity, _, ids) = make(storage: storage)
        XCTAssertEqual(identity.anonymousId(), "existing-anon-123")
        XCTAssertEqual(ids.count, 0, "no uuid minted when one is stored")
        XCTAssertEqual(storage.writes, 0)
    }

    func testAnEmptyStoredAnonymousIdIsReplaced() {
        let storage = InMemoryStore(["test_anonymous_id": ""])
        let (identity, _, _) = make(storage: storage)
        XCTAssertEqual(identity.anonymousId(), "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(storage.get("test_anonymous_id"), identity.anonymousId())
    }

    func testLoadsAnExistingUserId() {
        let storage = InMemoryStore(["test_user_id": "user-456"])
        let (identity, _, _) = make(storage: storage)
        XCTAssertEqual(identity.userId(), "user-456")
    }

    // MARK: getAnonymousId / setAnonymousId

    func testReturnsTheStoredAnonymousId() {
        let storage = InMemoryStore(["ns_anonymous_id": "stored-anon"])
        let (identity, _, _) = make("ns", storage: storage)
        XCTAssertEqual(identity.anonymousId(), "stored-anon")
    }

    func testSetAnonymousIdUpdatesAndPersists() {
        let (identity, storage, _) = make()
        identity.setAnonymousId("custom-anon-id")
        XCTAssertEqual(identity.anonymousId(), "custom-anon-id")
        XCTAssertEqual(storage.get("test_anonymous_id"), "custom-anon-id")
    }

    // MARK: getUserId / setUserId

    func testUserIdIsNilInitially() {
        let (identity, _, _) = make()
        XCTAssertNil(identity.userId())
    }

    func testSetUserIdSetsAndPersists() {
        let (identity, storage, _) = make()
        identity.setUserId("user-789")
        XCTAssertEqual(identity.userId(), "user-789")
        XCTAssertEqual(storage.get("test_user_id"), "user-789")
    }

    // MARK: reset

    func testResetClearsUserIdAndMintsANewAnonymousId() {
        let (identity, storage, _) = make()
        identity.setUserId("user-to-clear")
        let previous = identity.anonymousId()

        identity.reset()

        XCTAssertNil(identity.userId())
        XCTAssertNil(storage.get("test_user_id"))
        let fresh = identity.anonymousId()
        XCTAssertFalse(fresh.isEmpty)
        XCTAssertNotEqual(fresh, previous)
        XCTAssertEqual(fresh, "00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(storage.get("test_anonymous_id"), fresh)
    }

    // MARK: namespace isolation

    func testDifferentNamespacesUseDifferentKeys() {
        let storage = InMemoryStore()
        let ids = SequenceIdGenerator()
        let a = IdentityStore(keys: Keys(namespace: "brand_a"), storage: storage, ids: ids)
        let b = IdentityStore(keys: Keys(namespace: "brand_b"), storage: storage, ids: ids)
        a.setUserId("user-a")
        b.setUserId("user-b")
        XCTAssertEqual(a.userId(), "user-a")
        XCTAssertEqual(b.userId(), "user-b")
        XCTAssertEqual(storage.get("brand_a_user_id"), "user-a")
        XCTAssertEqual(storage.get("brand_b_user_id"), "user-b")
        XCTAssertNotEqual(a.anonymousId(), b.anonymousId())
    }

    func testSystemIdGeneratorMintsLowercaseV4Uuids() {
        let id = SystemIdGenerator().uuid()
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id.count, 36)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertNotEqual(SystemIdGenerator().uuid(), id)
    }
}
