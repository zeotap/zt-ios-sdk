import Foundation

/// Consent input — exactly one of three mutually exclusive forms, mirroring the browser SDK's
/// `ConsentInput` union (`consent.ts`). Serialised verbatim onto `context.consent`.
public enum ConsentInput: Equatable, Sendable {
    /// Raw IAB TCF v2 consent string; the server derives categories.
    case tcf(tcfString: String)
    /// Raw IAB US Privacy / CCPA string.
    case usPrivacy(String)
    /// Pre-resolved category booleans from the host's own CMP.
    case parsed(ParsedConsent)
}

/// Only non-nil members are serialised, in the canonical order analytics, marketing, advertising, functional.
public struct ParsedConsent: Equatable, Sendable {
    public var analytics: Bool?
    public var marketing: Bool?
    public var advertising: Bool?
    public var functional: Bool?

    public init(analytics: Bool? = nil, marketing: Bool? = nil, advertising: Bool? = nil, functional: Bool? = nil) {
        self.analytics = analytics
        self.marketing = marketing
        self.advertising = advertising
        self.functional = functional
    }
}

/// Per-action consent signals derived from a resolution (`consent-state.ts`).
public struct ConsentSignals: Equatable, Sendable {
    /// Gates track/screen/group/alias events.
    public let track: Bool
    /// Gates identify events and user-identity persistence.
    public let identify: Bool
    /// Browser cookie-sync gate. Mobile never cookie-syncs, but the signal is part of the
    /// persisted `{ns}_consent` record and is kept byte-compatible.
    public let cookieSync: Bool

    public init(track: Bool, identify: Bool, cookieSync: Bool) {
        self.track = track
        self.identify = identify
        self.cookieSync = cookieSync
    }

    /// All-granted / all-denied signal sets (`uniformSignals`).
    public static func uniform(_ granted: Bool) -> ConsentSignals {
        ConsentSignals(track: granted, identify: granted, cookieSync: granted)
    }
}

/// Where a resolution came from. Precedence: manual > cmp > storage > default.
public enum ConsentSource: String, Sendable, Comparable {
    case `default`
    case storage
    case cmp
    case manual

    var rank: Int {
        switch self {
        case .default: return 0
        case .storage: return 1
        case .cmp: return 2
        case .manual: return 3
        }
    }

    public static func < (lhs: ConsentSource, rhs: ConsentSource) -> Bool { lhs.rank < rhs.rank }
}

/// Read-only snapshot of the consent resolution (see `Analytics.getConsentState()`).
public struct ConsentStateSnapshot: Equatable, Sendable {
    public let resolved: Bool
    public let signals: ConsentSignals?
    public let source: ConsentSource?
    public let gdprApplies: Bool?

    public init(resolved: Bool, signals: ConsentSignals? = nil, source: ConsentSource? = nil, gdprApplies: Bool? = nil) {
        self.resolved = resolved
        self.signals = signals
        self.source = source
        self.gdprApplies = gdprApplies
    }

    public static let unresolved = ConsentStateSnapshot(resolved: false)
}

/// Resolution applied when no consent source answers within `cmpTimeoutMs`.
public enum ConsentDefault: String, Sendable {
    case granted
    case denied
}

/// TCF CMP integration mode: read the IAB TCF-for-Apps `IABTCF_*` defaults, or don't.
public enum CmpMode: String, Sendable {
    case auto
    case none
}

/// Identity of a wrapping integration (e.g. the React Native bridge) that installed the SDK.
/// Attached to every event as `context.library.integration`.
public struct IntegrationMeta: Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}
