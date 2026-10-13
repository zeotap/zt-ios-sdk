import Foundation
#if canImport(Security)
import Security
#endif

/// `KeyValueStore` over the Keychain (`IdentityStorage.keychain`): generic-password items with
/// service `com.zeotap.sdk.<namespace>`, account = key, `kSecAttrAccessibleAfterFirstUnlock` (the
/// SDK writes from background flushes), optional access group for app-group / extension sharing.
/// Identity survives reinstalls here — a deliberate semantics change the host opts into.
/// Without `Security` (Linux test host) it degrades to an `InMemoryStore`.
final class KeychainStore: KeyValueStore, @unchecked Sendable {
    let service: String
    let accessGroup: String?
    private let logger: Logger?

    #if !canImport(Security)
    private let fallback = InMemoryStore()
    #endif

    init(namespace: String, accessGroup: String? = nil, logger: Logger? = nil) {
        service = "com.zeotap.sdk.\(namespace)"
        self.accessGroup = accessGroup
        self.logger = logger
    }

    #if canImport(Security)
    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { report("read", status) }
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            #if !os(macOS)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #endif
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { report("write", status) }
    }

    func remove(_ key: String) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { report("delete", status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func report(_ op: String, _ status: OSStatus) {
        logger?.warn("[SDK] Keychain \(op) failed (OSStatus \(status))")
    }
    #else
    func get(_ key: String) -> String? { fallback.get(key) }

    func set(_ key: String, _ value: String) { fallback.set(key, value) }

    func remove(_ key: String) { fallback.remove(key) }
    #endif
}
