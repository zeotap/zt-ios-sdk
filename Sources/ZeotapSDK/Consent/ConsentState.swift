import Foundation

/// A resolved consent decision (`consent-state.ts` `ResolvedConsent`). `ts` is epoch milliseconds.
struct ResolvedConsent: Equatable, Sendable {
    var signals: ConsentSignals
    /// The host-provided input, when the source supplied one. Rides on `context.consent`.
    var input: ConsentInput?
    /// Raw TC string when CMP-sourced or supplied via `.tcf(tcfString:)`.
    var tcfString: String?
    var gdprApplies: Bool?
    var source: ConsentSource
    var ts: Int64

    init(signals: ConsentSignals, input: ConsentInput? = nil, tcfString: String? = nil, gdprApplies: Bool? = nil, source: ConsentSource, ts: Int64) {
        self.signals = signals
        self.input = input
        self.tcfString = tcfString
        self.gdprApplies = gdprApplies
        self.source = source
        self.ts = ts
    }
}

/// Pure consent-signal derivation — port of `consent-state.ts` `resolveSignals` and the cookie-sync
/// gate from `cookie-sync.ts` — plus the wire (JSON) form of a `ConsentInput` and `ConsentSignals`.
enum ConsentState {
    /// Parsed booleans: `track` requires `analytics != false` (absent grants), `identify` follows
    /// `track`. `{tcfString}` / `{usPrivacy}`: track and identify granted (server-side enforcement
    /// model). `cookieSync` is ALWAYS `consentPermitsSync` so this layer and the pixel gate cannot drift.
    static func resolveSignals(_ input: ConsentInput) -> ConsentSignals {
        let cookieSync = consentPermitsSync(input)
        switch input {
        case .tcf, .usPrivacy:
            return ConsentSignals(track: true, identify: true, cookieSync: cookieSync)
        case let .parsed(parsed):
            let track = parsed.analytics != false
            return ConsentSignals(track: track, identify: track, cookieSync: cookieSync)
        }
    }

    /// Whether cookie sync may run at all (`cookie-sync.ts` `consentPermitsSync`).
    static func consentPermitsSync(_ input: ConsentInput?) -> Bool {
        switch input {
        case .none: return false
        case let .tcf(tcfString): return !tcfString.isEmpty
        case let .usPrivacy(s): return usPrivacyPermitsSync(s)
        case let .parsed(parsed): return parsed.advertising == true || parsed.marketing == true
        }
    }

    /// IAB US Privacy: `[version][notice][opt-out of sale][LSPA]`, e.g. `1YNN`. The third UTF-16
    /// unit is the opt-out ('Y'/'y' = no sync). Strings shorter than 3 units fail safe.
    static func usPrivacyPermitsSync(_ s: String) -> Bool {
        let units = Array(s.utf16)
        guard units.count >= 3 else { return false }
        return units[2] != 0x59 && units[2] != 0x79 // "Y" / "y"
    }

    /// `{"tcfString":..}` | `{"usPrivacy":..}` | non-nil parsed booleans in order analytics, marketing, advertising, functional.
    static func toJSON(_ input: ConsentInput) -> JSONValue {
        switch input {
        case let .tcf(tcfString): return .object([("tcfString", .string(tcfString))])
        case let .usPrivacy(s): return .object([("usPrivacy", .string(s))])
        case let .parsed(parsed):
            var pairs: [(String, JSONValue)] = []
            if let v = parsed.analytics { pairs.append(("analytics", .bool(v))) }
            if let v = parsed.marketing { pairs.append(("marketing", .bool(v))) }
            if let v = parsed.advertising { pairs.append(("advertising", .bool(v))) }
            if let v = parsed.functional { pairs.append(("functional", .bool(v))) }
            return .object(pairs)
        }
    }

    /// Inverse of `toJSON`: a `tcfString` key wins, then `usPrivacy`, else parsed booleans
    /// (missing / non-boolean members → nil). `nil` when `value` is not an object.
    static func fromJSON(_ value: JSONValue) -> ConsentInput? {
        guard case .object = value else { return nil }
        if let tcf = value["tcfString"] { return .tcf(tcfString: tcf.stringValue ?? "") }
        if let usp = value["usPrivacy"] { return .usPrivacy(usp.stringValue ?? "") }
        return .parsed(ParsedConsent(
            analytics: value["analytics"]?.boolValue,
            marketing: value["marketing"]?.boolValue,
            advertising: value["advertising"]?.boolValue,
            functional: value["functional"]?.boolValue
        ))
    }

    /// `{"track":..,"identify":..,"cookieSync":..}` — key order is contractual for the persisted record.
    static func signalsToJSON(_ s: ConsentSignals) -> JSONValue {
        .object([("track", .bool(s.track)), ("identify", .bool(s.identify)), ("cookieSync", .bool(s.cookieSync))])
    }

    /// Missing or non-boolean members read as denied; `nil` when `value` is not an object.
    static func signalsFromJSON(_ value: JSONValue) -> ConsentSignals? {
        guard case .object = value else { return nil }
        return ConsentSignals(
            track: value["track"]?.boolValue ?? false,
            identify: value["identify"]?.boolValue ?? false,
            cookieSync: value["cookieSync"]?.boolValue ?? false
        )
    }
}
