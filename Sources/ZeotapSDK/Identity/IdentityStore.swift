import Foundation

/// Anonymous-id / user-id persistence — port of `sdk/js/src/identity.ts` over the SDK
/// `KeyValueStore`. The anonymous id is minted and persisted on first construction when absent.
/// Used from the SDK's serial queue only.
final class IdentityStore {
    private let keys: Keys
    private let storage: KeyValueStore
    private let ids: IdGenerator
    private var anonymous: String
    private var user: String?

    init(keys: Keys, storage: KeyValueStore, ids: IdGenerator) {
        self.keys = keys
        self.storage = storage
        self.ids = ids
        if let stored = storage.get(keys.anonymousId), !stored.isEmpty {
            anonymous = stored
        } else {
            anonymous = ids.uuid()
            storage.set(keys.anonymousId, anonymous)
        }
        if let stored = storage.get(keys.userId), !stored.isEmpty { user = stored }
    }

    func anonymousId() -> String { anonymous }

    /// Override the anonymous id (hybrid WebView / bridge use) and persist it.
    func setAnonymousId(_ id: String) {
        anonymous = id
        storage.set(keys.anonymousId, id)
    }

    func userId() -> String? { user }

    func setUserId(_ id: String) {
        user = id
        storage.set(keys.userId, id)
    }

    /// Logout: drop the user id and mint a fresh anonymous id.
    func reset() {
        user = nil
        storage.remove(keys.userId)
        anonymous = ids.uuid()
        storage.set(keys.anonymousId, anonymous)
    }
}
