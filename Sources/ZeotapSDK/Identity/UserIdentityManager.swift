import Foundation

/// PII user identities — port of `sdk/js/src/user-identities.ts`. Raw email/loginid/cellno input is
/// normalised and hashed synchronously; pre-hashed legacy flat keys are regrouped; fpuid and custom
/// keys pass through raw. The map is persisted verbatim (`JSONWriter`, insertion order kept) under
/// `{ns}_user_identities` and attaches to every event as `context.identities`.
///
/// Input is ORDERED (`[(key, value)]`) because the web's `{...existing, ...new}` merge order is
/// observable in the persisted JSON: existing keys keep their position, new keys append in input
/// order. Identity values are never logged. Used from the SDK's serial queue only.
final class UserIdentityManager {
    private let keys: Keys
    private let storage: KeyValueStore
    private let logger: Logger
    private var identities: [(String, JSONValue)]

    init(keys: Keys, storage: KeyValueStore, logger: Logger) {
        self.keys = keys
        self.storage = storage
        self.logger = logger
        identities = []
        identities = read()
    }

    /// Current identities as an ordered object, or `nil` when empty.
    func get() -> JSONValue? {
        identities.isEmpty ? nil : .object(identities)
    }

    /// Merge `{...existing, ...resolved}` — existing keys keep their position — and persist.
    func setIdentities(_ input: [(String, String?)], hashed: Bool) {
        let resolved = hashed ? regroupHashed(input) : hashRaw(input)
        var merged = identities
        for (key, value) in resolved { UserIdentityManager.put(&merged, key, value) }
        identities = merged
        persist()
    }

    /// Remove specific identity keys, or everything when `keys` is `nil` or empty.
    func unset(_ keys: [String]?) {
        if let keys, !keys.isEmpty {
            identities.removeAll { keys.contains($0.0) }
        } else {
            identities = []
        }
        persist()
    }

    /// Clear everything (reset / logout).
    func clear() {
        unset(nil)
    }

    // MARK: - Raw path

    private func hashRaw(_ input: [(String, String?)]) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        let explicitCc = input.last { $0.0 == UserIdentityManager.keyCellnoCc }?.1
        for (key, maybeValue) in input {
            guard let value = maybeValue, !value.isEmpty else { continue }
            if UserIdentityManager.caseKeys.contains(key) {
                UserIdentityManager.put(&out, key, UserIdentityManager.object(Hasher.caseVariants(value)))
            } else if key == UserIdentityManager.keyCellno {
                let cellno = Hasher.cleanCellno(value, explicitCc: explicitCc)
                guard !cellno.number.isEmpty else { continue }
                UserIdentityManager.put(&out, UserIdentityManager.keyCellno, UserIdentityManager.object(Hasher.digits(cellno.number)))
                if let cc = cellno.cc {
                    UserIdentityManager.put(&out, UserIdentityManager.keyCellnoE164, UserIdentityManager.object(Hasher.digits(cc + cellno.number)))
                }
            } else if key == UserIdentityManager.keyCellnoCc {
                continue // consumed alongside cellno, never emitted
            } else {
                UserIdentityManager.put(&out, key, .string(value)) // fpuid and custom keys pass through raw
            }
        }
        return out
    }

    // MARK: - Pre-hashed path

    private func regroupHashed(_ input: [(String, String?)]) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        for (key, maybeValue) in input {
            guard let value = maybeValue, !value.isEmpty else { continue }
            if let (base, variant) = UserIdentityManager.matchHashedCaseKey(key) {
                addToGroup(&out, base: base, variant: variant, value: value)
            } else if let (base, algo) = UserIdentityManager.matchHashedDigitKey(key) {
                addToGroup(&out, base: base, variant: algo, value: value)
            } else {
                UserIdentityManager.put(&out, key, .string(value)) // fpuid / custom ids stay raw even in hashed mode
            }
        }
        return out
    }

    private func addToGroup(_ out: inout [(String, JSONValue)], base: String, variant: String, value: String) {
        var group: [(String, JSONValue)] = []
        if let index = out.firstIndex(where: { $0.0 == base }), case let .object(existing) = out[index].1 { group = existing }
        UserIdentityManager.put(&group, variant, .string(value))
        UserIdentityManager.put(&out, base, .object(group))
    }

    /// `^(email|loginid)_(sha256|sha1|md5)_(lowercase|uppercase)$` → (base, "algo_casing").
    static func matchHashedCaseKey(_ key: String) -> (String, String)? {
        for casing in ["lowercase", "uppercase"] {
            guard key.hasSuffix("_" + casing) else { continue }
            let withoutCasing = String(key.dropLast(casing.count + 1))
            for algo in hashAlgos {
                guard withoutCasing.hasSuffix("_" + algo) else { continue }
                let base = String(withoutCasing.dropLast(algo.count + 1))
                return caseKeys.contains(base) ? (base, algo + "_" + casing) : nil
            }
            return nil
        }
        return nil
    }

    /// `^(cellno|cellno_e164|cellno_with_country_code|cellno_without_country_code)_(sha256|sha1|md5)$` → (base, algo).
    static func matchHashedDigitKey(_ key: String) -> (String, String)? {
        for algo in hashAlgos {
            guard key.hasSuffix("_" + algo) else { continue }
            let base = String(key.dropLast(algo.count + 1))
            return digitBases.contains(base) ? (base, algo) : nil
        }
        return nil
    }

    // MARK: - Persistence

    private func read() -> [(String, JSONValue)] {
        guard let raw = storage.get(keys.userIdentities), !raw.isEmpty else { return [] }
        guard let parsed = JSONParser.parseOrdered(raw) else {
            logger.warn("[SDK] Ignoring corrupt user identities record")
            return []
        }
        guard case let .object(pairs) = parsed else {
            logger.warn("[SDK] Ignoring malformed user identities record")
            return []
        }
        return pairs
    }

    private func persist() {
        if identities.isEmpty {
            storage.remove(keys.userIdentities)
        } else {
            storage.set(keys.userIdentities, JSONWriter.string(.object(identities)))
        }
    }

    // MARK: - Helpers

    private static func put(_ pairs: inout [(String, JSONValue)], _ key: String, _ value: JSONValue) {
        if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value } else { pairs.append((key, value)) }
    }

    private static func object(_ strings: [(String, String)]) -> JSONValue {
        .object(strings.map { ($0.0, JSONValue.string($0.1)) })
    }

    private static let keyCellno = "cellno"
    private static let keyCellnoCc = "cellno_cc"
    private static let keyCellnoE164 = "cellno_e164"
    /// Identity keys the SDK hashes case-sensitively.
    private static let caseKeys: Set<String> = ["email", "loginid"]
    private static let hashAlgos = ["sha256", "sha1", "md5"]
    private static let digitBases: Set<String> = ["cellno", "cellno_e164", "cellno_with_country_code", "cellno_without_country_code"]
}
