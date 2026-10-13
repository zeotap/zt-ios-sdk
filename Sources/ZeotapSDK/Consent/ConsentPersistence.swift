import Foundation

/// Persisted consent — port of `sdk/js/src/consent-persistence.ts`. Two records in the
/// `KeyValueStore`: `{ns}_consent` = `{"v":1,"signals","input"?,"gdprApplies"?,"source","ts","exp"}`
/// and the side key `{ns}_consent_tcf` = `{"v":1,"tcfString","ts","exp"}` (the TC string never rides
/// in the main record). Hydration yields source `.storage` with the record's ORIGINAL `ts`; saves
/// are skipped when the decision is unchanged. Used from the SDK's serial queue only.
final class ConsentPersistence {
    private struct StoredRecord {
        let signals: ConsentSignals
        let input: ConsentInput?
        let gdprApplies: Bool?
        let ts: Int64
        let exp: Int64
    }

    private let keys: Keys
    private let storage: KeyValueStore
    private let expiryDays: Int
    private let clock: Clock

    init(keys: Keys, storage: KeyValueStore, expiryDays: Int, clock: Clock) {
        self.keys = keys
        self.storage = storage
        self.expiryDays = expiryDays
        self.clock = clock
    }

    /// The persisted resolution, or `nil` when absent / expired / corrupt (both keys are then removed).
    func load() -> ResolvedConsent? {
        guard let record = readRecord() else { return nil }
        return ResolvedConsent(
            signals: record.signals,
            input: record.input,
            tcfString: readTcfString(),
            gdprApplies: record.gdprApplies,
            source: .storage,
            ts: record.ts
        )
    }

    /// Persist; skipped when signals, input (after stripping a `.tcf` input), gdprApplies AND the
    /// stored TC string are all unchanged — `exp` is NOT refreshed in that case (web parity).
    func save(_ resolution: ResolvedConsent) {
        let now = clock.nowMs()
        // A manual {tcfString} input is stored via the side key, not inline.
        var input = resolution.input
        if case .tcf = input { input = nil }

        // Same short-circuit order as the web: the side key is only read when the decision matches.
        if let existing = readRecord(),
           existing.signals == resolution.signals,
           existing.input == input,
           existing.gdprApplies == resolution.gdprApplies,
           readTcfString() == resolution.tcfString {
            return
        }

        var record: [(String, JSONValue)] = [
            ("v", .int(1)),
            ("signals", ConsentState.signalsToJSON(resolution.signals))
        ]
        if let input { record.append(("input", ConsentState.toJSON(input))) }
        if let gdprApplies = resolution.gdprApplies { record.append(("gdprApplies", .bool(gdprApplies))) }
        record.append(("source", .string(resolution.source.rawValue)))
        record.append(("ts", .int(resolution.ts)))
        record.append(("exp", .int(now + ttlMs)))
        storage.set(keys.consent, JSONWriter.string(.object(record)))
        writeTcfString(resolution.tcfString, now: now)
    }

    /// Remove both keys (reset / consent withdrawal).
    func clear() {
        storage.remove(keys.consent)
        storage.remove(keys.consentTcf)
    }

    // MARK: - Private

    private var ttlMs: Int64 { Int64(expiryDays) * ConsentPersistence.dayMs }

    private func readRecord() -> StoredRecord? {
        guard let raw = storage.get(keys.consent), !raw.isEmpty else { return nil }
        guard let record = ConsentPersistence.parseRecord(raw), record.exp > clock.nowMs() else {
            clear()
            return nil
        }
        return record
    }

    /// `JSON.parse` then `record.v !== 1 || typeof record.exp !== "number" || !record.signals` → nil.
    private static func parseRecord(_ raw: String) -> StoredRecord? {
        guard let parsed = JSONParser.parseOrdered(raw), case .object = parsed else { return nil }
        guard parsed["v"]?.intValue == 1, let exp = parsed["exp"]?.intValue,
              let signalsValue = parsed["signals"], let signals = ConsentState.signalsFromJSON(signalsValue) else { return nil }
        return StoredRecord(
            signals: signals,
            input: parsed["input"].flatMap(ConsentState.fromJSON),
            gdprApplies: parsed["gdprApplies"]?.boolValue,
            ts: parsed["ts"]?.intValue ?? 0,
            exp: exp
        )
    }

    /// The side record's TC string. Invalid (wrong version, expired, empty) → key removed, nil.
    /// Unparseable → nil but the key is LEFT in place (the web read is try/caught without cleanup).
    private func readTcfString() -> String? {
        guard let raw = storage.get(keys.consentTcf), !raw.isEmpty else { return nil }
        guard let parsed = JSONParser.parseOrdered(raw) else { return nil }
        if parsed.isNull { return nil } // JS: `null.v` throws inside the try → undefined, key kept
        let tcfString = parsed["tcfString"]?.stringValue
        let expired = parsed["exp"]?.intValue.map { $0 <= clock.nowMs() } ?? false
        guard parsed["v"]?.intValue == 1, !expired, let tcfString, !tcfString.isEmpty else {
            storage.remove(keys.consentTcf)
            return nil
        }
        return tcfString
    }

    private func writeTcfString(_ tcfString: String?, now: Int64) {
        guard let tcfString, !tcfString.isEmpty else {
            storage.remove(keys.consentTcf)
            return
        }
        let record: JSONValue = .object([
            ("v", .int(1)),
            ("tcfString", .string(tcfString)),
            ("ts", .int(now)),
            ("exp", .int(now + ttlMs))
        ])
        storage.set(keys.consentTcf, JSONWriter.string(record))
    }

    private static let dayMs: Int64 = 86_400_000
}
