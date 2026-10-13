import Foundation

/// Consent behaviour configuration — same names and defaults as the browser SDK's
/// `ConsentOptions` (`client.ts`). With the defaults, events flow immediately and consent is
/// merely attached to payloads. Gating activates when `require` is true or `default` is `.denied`.
public struct ConsentOptions: Equatable, Sendable {
    /// Opt-in mode: buffer events until consent resolves, then replay or drop.
    public var require: Bool = false
    /// Resolution applied when no source answers within `cmpTimeoutMs`.
    public var `default`: ConsentDefault = .granted
    /// How long to wait for a consent source before resolving with `default` (ms — web unit kept).
    public var cmpTimeoutMs: Int = 10_000
    /// Max events buffered while consent is unresolved; beyond this the newest is dropped.
    public var maxBufferedEvents: Int = 10
    /// TCF-for-Apps integration. `nil` resolves to `.auto` when `require`, else `.none`.
    public var cmp: CmpMode?
    /// TCF purposes that must ALL be consented for tracking. Empty = either [1,3,4] or [1,5,6].
    public var purposesForTracking: [Int] = []
    /// TCF purposes for identify (always plus Zeotap vendor consent). Empty = [1,9].
    public var purposesForIdentifying: [Int] = []
    /// TCF purposes feeding the persisted `cookieSync` signal. Empty = either [1,3,4] or [1,5,6].
    public var purposesForCookieSync: [Int] = []
    /// Also require Zeotap vendor consent (GVL 1469 / legacy 301) for tracking.
    public var checkVendorConsent: Bool = false
    /// Persist resolved consent across launches.
    public var persist: Bool = true
    /// Persisted consent TTL in days.
    public var expiryDays: Int = 365

    public init() {}

    /// The effective CMP mode after applying the web default (`require ? "auto" : "none"`).
    public var resolvedCmp: CmpMode { cmp ?? (require ? .auto : .none) }

    /// Whether consent gating is active (opt-in mode or opt-out-by-default).
    public var gatingActive: Bool { require || `default` == .denied }

    /// Throws `ZeotapError.invalidConfiguration` on out-of-range values.
    func validate() throws {
        guard cmpTimeoutMs > 0 else { throw ZeotapError.invalidConfiguration("consent.cmpTimeoutMs must be > 0") }
        guard maxBufferedEvents >= 0 else { throw ZeotapError.invalidConfiguration("consent.maxBufferedEvents must be >= 0") }
        guard expiryDays > 0 else { throw ZeotapError.invalidConfiguration("consent.expiryDays must be > 0") }
    }
}
