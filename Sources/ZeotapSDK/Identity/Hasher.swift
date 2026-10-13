import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// PII hashing — port of `sdk/js/src/hash.ts`: SHA-256 / SHA-1 lowercase hex over UTF-8, ECMAScript
/// `trim()` then full-Unicode casing before hashing, and the legacy `"<cc> <number>"` cellno split.
/// MD5 is never produced on-device (web parity). No Unicode normalisation is applied.
enum Hasher {
    /// Lowercase hex SHA-256 of the UTF-8 encoding (Swift strings cannot hold lone surrogates, so
    /// the `TextEncoder` U+FFFD replacement case cannot arise).
    static func sha256Hex(_ input: String) -> String {
        hex(SHA256.hash(data: Data(input.utf8)))
    }

    /// Lowercase hex SHA-1 of the UTF-8 encoding.
    static func sha1Hex(_ input: String) -> String {
        hex(Insecure.SHA1.hash(data: Data(input.utf8)))
    }

    /// The legacy 4-key matrix for case-sensitive identities (email, loginid): `trim()`, then
    /// lower/upper with the full Unicode mapping (`ß` → `SS`, `İ` → `i̇`), then hash. Key order is
    /// contractual (`sha256_lowercase, sha256_uppercase, sha1_lowercase, sha1_uppercase`).
    static func caseVariants(_ value: String) -> [(String, String)] {
        let trimmed = jsTrim(value)
        let lower = trimmed.lowercased()
        let upper = trimmed.uppercased()
        return [
            ("sha256_lowercase", sha256Hex(lower)),
            ("sha256_uppercase", sha256Hex(upper)),
            ("sha1_lowercase", sha1Hex(lower)),
            ("sha1_uppercase", sha1Hex(upper))
        ]
    }

    /// Digits-only identities (cellno family): sha256 + sha1 of the exact string.
    static func digits(_ value: String) -> [(String, String)] {
        [("sha256", sha256Hex(value)), ("sha1", sha1Hex(value))]
    }

    /// A normalised cell number; `cc` is `nil` when no country code was recognised.
    struct Cellno: Equatable {
        let number: String
        let cc: String?
    }

    /// Literal port of `cleanCellno` (hash.ts): trim; an explicit cc is digit-stripped (an empty
    /// explicit cc counts as absent); a `"<cc> <number>"` split happens only when the token before
    /// the first ASCII space matches `^\+?[0-9]{1,4}$`; the number keeps ASCII digits only. As in
    /// JS, an explicit cc that strips to `""` still suppresses the inline prefix (`??` keeps the
    /// empty string) and is then reported as `nil` (`cc || undefined`).
    static func cleanCellno(_ raw: String, explicitCc: String?) -> Cellno {
        let trimmed = Array(jsTrim(raw).unicodeScalars)
        var cc: String?
        if let explicit = explicitCc, !explicit.isEmpty { cc = asciiDigits(explicit.unicodeScalars) }
        var numberPart = trimmed[...]

        if let spaceIdx = trimmed.firstIndex(of: " "), spaceIdx > 0 {
            // Only a clean "+91"-style prefix token is a country code — a formatted token like
            // "(999)" is number formatting, not the legacy cc convention.
            let prefix = trimmed[0..<spaceIdx]
            if isCcPrefix(prefix) {
                if cc == nil { cc = asciiDigits(prefix) }
                numberPart = trimmed[(spaceIdx + 1)...]
            }
        }

        let number = asciiDigits(numberPart)
        return Cellno(number: number, cc: (cc?.isEmpty ?? true) ? nil : cc)
    }

    /// ECMAScript `String.prototype.trim()`: strips WhiteSpace (TAB, VT, FF, SP, NBSP, ZWNBSP and
    /// every `Zs` character) and LineTerminator (LF, CR, LS, PS) from both ends. Deliberately NOT
    /// `CharacterSet.whitespacesAndNewlines`, whose membership differs (U+001C–U+001F, U+0085).
    static func jsTrim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isJsWhitespace(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isJsWhitespace(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    // MARK: - Private

    private static func isJsWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029: return true
        default: return c.properties.generalCategory == .spaceSeparator
        }
    }

    /// `^\+?[0-9]{1,4}$` over scalars.
    private static func isCcPrefix<C: Collection>(_ prefix: C) -> Bool where C.Element == Unicode.Scalar {
        var digits = prefix[...]
        if digits.first == "+" { digits = digits.dropFirst() }
        guard (1...4).contains(digits.count) else { return false }
        return digits.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    /// JS `replace(/[^\d]/g, "")` without the `u` flag — ASCII 0-9 only.
    private static func asciiDigits<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        for c in scalars where c.value >= 0x30 && c.value <= 0x39 { out.append(c) }
        return String(out)
    }

    private static let hexTable: [Character] = Array("0123456789abcdef")

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexTable[Int(byte >> 4)])
            out.append(hexTable[Int(byte & 0x0F)])
        }
        return out
    }
}
