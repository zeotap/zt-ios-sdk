import Foundation

/// Process-wide facade — the equivalent of the browser SDK's `window.zeotap`.
///
/// ```swift
/// try Zeotap.configure(writeKey: "wk_…") { $0.apiHost = "https://events.zeotap.com" }
/// Zeotap.track("Button Clicked", properties: ["label": "signup"])
/// ```
///
/// `configure` is idempotent (a second call returns the existing instance). Every other static
/// before `configure` is a logged no-op that reports `ZeotapError.notConfigured` to its
/// completion — never a crash.
public enum Zeotap {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var instance: Analytics?

    /// Initialise once. Later calls return the existing instance and ignore the new configuration.
    @discardableResult
    public static func configure(writeKey: String, namespace: String = "zeotap", _ build: (inout Configuration) -> Void = { _ in }) throws -> Analytics {
        lock.lock()
        defer { lock.unlock() }
        if let existing = instance { return existing }
        var configuration = Configuration(apiHost: "")
        build(&configuration)
        let created = try Analytics(writeKey: writeKey, namespace: namespace, configuration: configuration)
        instance = created
        return created
    }

    /// The live instance, or nil before `configure`.
    public static var shared: Analytics? {
        lock.lock()
        defer { lock.unlock() }
        return instance
    }

    public static var isConfigured: Bool { shared != nil }

    private static func ready(_ method: String, completion: Callback?) -> Analytics? {
        if let sdk = shared { return sdk }
        let error = ZeotapError.notConfigured(method: method)
        if let completion { DispatchQueue.main.async { completion(error) } }
        return nil
    }

    public static func identify(userId: String? = nil, traits: [String: Any]? = nil, completion: Callback? = nil) {
        ready("identify", completion: completion)?.identify(userId: userId, traits: traits, completion: completion)
    }

    public static func track(_ event: String, properties: [String: Any]? = nil, completion: Callback? = nil) {
        ready("track", completion: completion)?.track(event, properties: properties, completion: completion)
    }

    public static func screen(_ name: String? = nil, category: String? = nil, properties: [String: Any]? = nil, completion: Callback? = nil) {
        ready("screen", completion: completion)?.screen(name, category: category, properties: properties, completion: completion)
    }

    public static func group(_ groupId: String, traits: [String: Any]? = nil, completion: Callback? = nil) {
        ready("group", completion: completion)?.group(groupId, traits: traits, completion: completion)
    }

    public static func alias(_ newId: String, previousId: String? = nil, completion: Callback? = nil) {
        ready("alias", completion: completion)?.alias(newId, previousId: previousId, completion: completion)
    }

    public static func setConsent(_ consent: ConsentInput) {
        ready("setConsent", completion: nil)?.setConsent(consent)
    }

    public static func setUserIdentities(_ identities: [String: String], hashed: Bool = false, completion: Callback? = nil) {
        ready("setUserIdentities", completion: completion)?.setUserIdentities(identities, hashed: hashed, completion: completion)
    }

    public static func unsetUserIdentities(_ keys: [String]? = nil) {
        ready("unsetUserIdentities", completion: nil)?.unsetUserIdentities(keys)
    }

    /// Safe before `configure`: returns the unresolved snapshot (web parity).
    public static func getConsentState() -> ConsentStateSnapshot { shared?.getConsentState() ?? .unresolved }

    /// See `Analytics.setAdvertisingId(_:trackingAuthorized:)`. A no-op before `configure`.
    public static func setAdvertisingId(_ id: String?, trackingAuthorized: Bool) {
        shared?.setAdvertisingId(id, trackingAuthorized: trackingAuthorized)
    }

    public static func reset() {
        ready("reset", completion: nil)?.reset()
    }

    /// Silent no-op before `configure` (web parity).
    public static func flush(completion: (() -> Void)? = nil) {
        shared?.flush(completion: completion)
    }

    /// Tear down the singleton so the next `configure` starts fresh. Tests only.
    public static func shutdownForTesting() {
        lock.lock()
        let existing = instance
        instance = nil
        lock.unlock()
        existing?.shutdown()
    }
}
