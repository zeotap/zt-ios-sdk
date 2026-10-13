import Foundation

/// TCF purpose/vendor consents → SDK signals — port of `sdk/js/src/tcf.ts` `translateTCData`, fed
/// by the IAB TCF-for-Apps bit strings (`'0'`/`'1'`, position i ↔ id i+1).
enum TcfTranslator {
    /// Zeotap's IAB Global Vendor List id.
    static let zeotapGVLId = 1469
    /// Legacy Zeotap GVL id — checked until all clients migrate.
    static let zeotapGVLOldId = 301

    /// Default purpose sets (either group must be fully consented).
    static let defaultTrackingPurposes: [[Int]] = [[1, 3, 4], [1, 5, 6]]
    static let defaultIdentifyingPurposes: [Int] = [1, 9]
    static let defaultCookieSyncPurposes: [[Int]] = [[1, 3, 4], [1, 5, 6]]

    /// `nil` (key absent) → nil; `""` → empty map; otherwise `{i+1: bits[i] == '1'}`.
    static func bitStringToConsents(_ bits: String?) -> [Int: Bool]? {
        guard let bits else { return nil }
        var out: [Int: Bool] = [:]
        out.reserveCapacity(bits.unicodeScalars.count)
        for (offset, scalar) in bits.unicodeScalars.enumerated() { out[offset + 1] = scalar == "1" }
        return out
    }

    /// - track: configured purposes (all required) or either default group; plus Zeotap vendor
    ///   consent when `checkVendorConsent`.
    /// - identify: ALWAYS requires Zeotap vendor consent, plus purposes (default [1,9]).
    /// - cookieSync: configured purposes or either default group.
    /// No purpose map at all → everything denied.
    static func translate(purposeConsents: [Int: Bool]?, vendorConsents: [Int: Bool]?, options: ConsentOptions) -> ConsentSignals {
        guard let consents = purposeConsents else { return .uniform(false) }
        let vendorOk = hasZeotapVendorConsent(vendorConsents)

        let track: Bool
        if options.checkVendorConsent && !vendorOk {
            track = false
        } else if !options.purposesForTracking.isEmpty {
            track = every(consents, options.purposesForTracking)
        } else {
            track = anyGroup(consents, defaultTrackingPurposes)
        }

        let identifyPurposes = options.purposesForIdentifying.isEmpty ? defaultIdentifyingPurposes : options.purposesForIdentifying
        let identify = vendorOk && every(consents, identifyPurposes)

        let cookieSync = options.purposesForCookieSync.isEmpty
            ? anyGroup(consents, defaultCookieSyncPurposes)
            : every(consents, options.purposesForCookieSync)

        return ConsentSignals(track: track, identify: identify, cookieSync: cookieSync)
    }

    static func translate(_ tcData: TcData, options: ConsentOptions) -> ConsentSignals {
        translate(
            purposeConsents: bitStringToConsents(tcData.purposeConsents),
            vendorConsents: bitStringToConsents(tcData.vendorConsents),
            options: options
        )
    }

    private static func hasZeotapVendorConsent(_ vendorConsents: [Int: Bool]?) -> Bool {
        guard let vendorConsents else { return false }
        return vendorConsents[zeotapGVLId] == true || vendorConsents[zeotapGVLOldId] == true
    }

    private static func every(_ consents: [Int: Bool], _ purposes: [Int]) -> Bool {
        purposes.allSatisfy { consents[$0] == true }
    }

    private static func anyGroup(_ consents: [Int: Bool], _ groups: [[Int]]) -> Bool {
        groups.contains { every(consents, $0) }
    }
}
