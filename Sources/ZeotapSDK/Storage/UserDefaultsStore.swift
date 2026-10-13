import Foundation

/// Default `KeyValueStore`: a dedicated `UserDefaults` suite (`com.zeotap.sdk`), so the SDK's keys
/// never collide with the host's `.standard` defaults and an uninstall clears the identity (the
/// web's cookie/localStorage semantics). Falls back to `.standard` when the suite cannot be created.
final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    static let defaultSuiteName = "com.zeotap.sdk"

    private let defaults: UserDefaults

    init(suiteName: String = UserDefaultsStore.defaultSuiteName) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Inject a specific `UserDefaults` (tests use an isolated suite).
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func get(_ key: String) -> String? {
        // A foreign non-string value under our key reads as absent.
        defaults.object(forKey: key) as? String
    }

    func set(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
