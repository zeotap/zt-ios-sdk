import Foundation

/// The SDK client — the browser SDK's `AnalyticsClient` for iOS. One instance per write key. Most
/// hosts use the `Zeotap` facade; multi-brand hosts create instances directly.
///
/// Every method is safe to call from any thread: work is posted to the SDK's serial queue, which
/// preserves call order (an event issued right after `setUserIdentities` carries the identities).
/// Callbacks are delivered on `Configuration.callbackQueue` (main by default).
///
/// Business logic (payload shape, consent gating, hashing, retry policy) is byte-compatible with
/// the browser SDK and pinned by `sdk/conformance`.
public final class Analytics: @unchecked Sendable {
    private let core: AnalyticsCore

    init(core: AnalyticsCore) {
        self.core = core
    }

    /// Create a configured instance. Throws `ZeotapError.missingWriteKey` (web: `[SDK] writeKey is
    /// required`), `.invalidApiHost` or `.invalidConfiguration`.
    public convenience init(writeKey: String, namespace: String = "zeotap", configuration: Configuration) throws {
        guard !writeKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw ZeotapError.missingWriteKey }
        var config = configuration
        config.namespace = namespace
        let validated = try config.validated()
        self.init(core: SdkFactory.create(writeKey: writeKey, configuration: validated))
        core.start()
    }

    /// Identify a user with traits. Persisting the user id is a consent-gated side effect.
    public func identify(userId: String? = nil, traits: [String: Any]? = nil, completion: Callback? = nil) {
        core.identify(userId: userId, traits: traits, completion: completion)
    }

    /// Track a named event. An empty name is a silent no-op (web parity).
    public func track(_ event: String, properties: [String: Any]? = nil, completion: Callback? = nil) {
        core.track(event, properties: properties, completion: completion)
    }

    /// Record a screen view.
    public func screen(_ name: String? = nil, category: String? = nil, properties: [String: Any]? = nil, completion: Callback? = nil) {
        core.screen(category: category, name: name, properties: properties, completion: completion)
    }

    /// Associate the current user with a group. An empty groupId is a silent no-op.
    public func group(_ groupId: String, traits: [String: Any]? = nil, completion: Callback? = nil) {
        core.group(groupId, traits: traits, completion: completion)
    }

    /// Alias a new user id to a previous one (defaults to the current anonymous id).
    public func alias(_ newId: String, previousId: String? = nil, completion: Callback? = nil) {
        core.alias(newId, previousId: previousId, completion: completion)
    }

    /// Set consent (source `manual`, the strongest). Attached to `context.consent` on later events.
    public func setConsent(_ consent: ConsentInput) {
        core.setConsent(consent)
    }

    /// Set PII identities. Raw values are normalised and hashed on-device (SHA-256/SHA-1 — never
    /// sent raw); pass `hashed: true` for pre-hashed legacy-key input. Attached to every later
    /// event as `context.identities`. Gated by the identify consent signal.
    ///
    /// Swift dictionaries are unordered, so keys are applied in the canonical order
    /// email, cellno, cellno_cc, loginid, fpuid, then the remaining keys alphabetically.
    public func setUserIdentities(_ identities: [String: String], hashed: Bool = false, completion: Callback? = nil) {
        core.setUserIdentities(Analytics.ordered(identities), hashed: hashed, completion: completion)
    }

    /// Remove specific identity keys, or all when `keys` is nil/empty. Never consent-gated.
    public func unsetUserIdentities(_ keys: [String]? = nil) {
        core.unsetUserIdentities(keys)
    }

    /// Read-only snapshot of the consent resolution. Callable from any thread.
    public func getConsentState() -> ConsentStateSnapshot { core.getConsentState() }

    /// Current anonymous id (for hybrid WebView / bridge use).
    public var anonymousId: String { core.anonymousId() }

    /// Current user id, if identified.
    public var userId: String? { core.userId() }

    /// Logout: new anonymous id, drop user id, identities, queued and buffered events, and consent
    /// (back to unresolved; the default timer re-arms). Call `flush()` first to keep pending events.
    public func reset() {
        core.reset()
    }

    /// Send queued events now. `completion` runs on the callback queue once the attempt finished.
    public func flush(completion: (() -> Void)? = nil) {
        core.flush(completion: completion)
    }

    /// Supply the advertising identifier yourself, instead of letting the SDK look it up.
    ///
    /// For an app whose IDFA comes from a mediation SDK, or one that links
    /// `ZeotapSDKAdSupport` nowhere and reads ATT itself. Takes effect for subsequent
    /// events — the value is read once per payload, never mid-payload — and a host-supplied
    /// value always wins over `Configuration.advertisingIdProvider`, which is not even
    /// consulted while one is set. Pass `id: nil` to **withdraw** an id after the user opts
    /// out; that is distinct from never having called this at all.
    ///
    /// **Requires `Configuration.collectAdvertisingId = true`.** Without it the device block
    /// carries no advertising id and this call is inert; the SDK logs a warning rather than
    /// failing, because the flag is the host's single switch for "may I collect this" and
    /// one call site should not be able to override it. Same rule as Android.
    ///
    /// - Parameter trackingAuthorized: ATT authorisation. When false the id is not sent and
    ///   `adTrackingEnabled: false` is — which is the point of reporting it. Android spells
    ///   the same parameter `limitAdTracking` (inverted): each platform keeps its own
    ///   vocabulary rather than inventing a third, and the React Native bridge exposes both
    ///   under `Zeotap.ios` / `Zeotap.android` so neither meaning is silently coerced.
    public func setAdvertisingId(_ id: String?, trackingAuthorized: Bool) {
        core.setAdvertisingId(id, trackingAuthorized: trackingAuthorized)
    }

    public func addListener(_ listener: SdkListener) {
        core.addListener(listener)
    }

    public func removeListener(_ listener: SdkListener) {
        core.removeListener(listener)
    }

    /// Stop timers and observers and close the queue. The instance is unusable afterwards.
    public func shutdown() {
        core.shutdown()
    }

    static let canonicalIdentityOrder = ["email", "cellno", "cellno_cc", "loginid", "fpuid"]

    static func ordered(_ identities: [String: String]) -> [(String, String?)] {
        var pairs: [(String, String?)] = []
        for key in canonicalIdentityOrder where identities[key] != nil { pairs.append((key, identities[key])) }
        for key in identities.keys.sorted() where !canonicalIdentityOrder.contains(key) { pairs.append((key, identities[key])) }
        return pairs
    }
}
