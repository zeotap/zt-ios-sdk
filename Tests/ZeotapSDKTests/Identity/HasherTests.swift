import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/hash.test.ts` — digests (constants verified against `node:crypto` /
/// `hashlib`), the case-variant matrix, digits and `cleanCellno`, plus the ECMAScript-trim and
/// full-Unicode casing edge cases the web relies on implicitly.
final class HasherTests: XCTestCase {
    private let sha256TestEmail = "973dfe463ec85785f5f95af5ba3906eedb2d931c24e69824a89ea65dba4e813b"
    private let sha1TestEmail = "567159d622ffbb50b11b0efd307be358624a26ee"
    private let sha256Lower = "b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514"
    private let sha256Upper = "c5ac93927855fbdde05d3ce09b70ccdd9d4e24ede68b98159632cd3b2cca3f49"
    private let sha1Lower = "63a710569261a24b3766275b7000ce8d7b32e2f7"
    private let sha1Upper = "31dfe4ea5fea6d1a07549d9e2123cf4a552349b7"

    // MARK: digestHex

    func testDigestsMatchNodeCryptoForSha256AndSha1() {
        XCTAssertEqual(Hasher.sha256Hex("test@example.com"), sha256TestEmail)
        XCTAssertEqual(Hasher.sha1Hex("test@example.com"), sha1TestEmail)
    }

    func testDigestsAreLowercaseHexOverUtf8() {
        XCTAssertEqual(Hasher.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hasher.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Hasher.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hasher.sha1Hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        // U+00E9 (NFC) and e + U+0301 (NFD) are different byte sequences — no normalisation.
        XCTAssertNotEqual(Hasher.sha256Hex("\u{E9}"), Hasher.sha256Hex("e\u{301}"))
        XCTAssertEqual(Hasher.sha256Hex("\u{E9}"), "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
        XCTAssertEqual(Hasher.sha256Hex("🙂@example.io"), "8cba8bd96d9d3d7d66ac840e127e5e405fcd1089b1a8e55ea36bbeb6a15018ca")
    }

    // MARK: hashCaseVariants

    func testCaseVariantsProduceTheLegacy4KeyMatrixWithCaseAppliedBeforeHashing() {
        let out = Hasher.caseVariants("  User@Example.COM ")
        XCTAssertEqual(out.map(\.0), ["sha256_lowercase", "sha256_uppercase", "sha1_lowercase", "sha1_uppercase"])
        XCTAssertEqual(out.map(\.1), [sha256Lower, sha256Upper, sha1Lower, sha1Upper])
    }

    func testCaseVariantsTrimTheEcmaScriptWhitespaceSet() {
        // NBSP, ZWNBSP, line/paragraph separators and Zs characters are all trimmed by JS trim().
        let padded = [
            "\u{A0}User@Example.COM\u{A0}",
            "\u{FEFF}User@Example.COM\t\n",
            "\u{2028}User@Example.COM\u{2029}",
            "\u{3000}User@Example.COM\u{2003}",
            "\u{0B}\u{0C}User@Example.COM\r"
        ]
        for padded in padded {
            XCTAssertEqual(Hasher.caseVariants(padded).first?.1, sha256Lower, "trim of \(padded.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // U+0085 and U+001C–U+001F are NOT JS whitespace (they are in CharacterSet.whitespacesAndNewlines).
        XCTAssertNotEqual(Hasher.caseVariants("\u{85}User@Example.COM").first?.1, sha256Lower)
        XCTAssertNotEqual(Hasher.caseVariants("\u{1F}User@Example.COM").first?.1, sha256Lower)
    }

    func testCaseVariantsUseFullUnicodeCaseMapping() {
        // "ß".toUpperCase() === "SS"
        XCTAssertEqual(Hasher.caseVariants("straße@example.de")[1].1, Hasher.sha256Hex("STRASSE@EXAMPLE.DE"))
        XCTAssertEqual(Hasher.caseVariants("straße@example.de")[1].1, "fd3cb47d5c6af18920db606881aedb3c1f28684c82e6eab0fe49bfcf304aa8ba")
        // "İ".toLowerCase() === "i̇" (i + U+0307)
        XCTAssertEqual(Hasher.caseVariants("İstanbul@example.com")[0].1, Hasher.sha256Hex("i\u{307}stanbul@example.com"))
        XCTAssertEqual(Hasher.caseVariants("İstanbul@example.com")[0].1, "21b3d4ad954ffe193659bcdcff92053ab646244b3898969a09265d00b2af7ba4")
    }

    func testJsTrimOnlyStripsTheEnds() {
        XCTAssertEqual(Hasher.jsTrim("  a b  "), "a b")
        XCTAssertEqual(Hasher.jsTrim("\u{A0}\u{FEFF}x\u{2028}"), "x")
        XCTAssertEqual(Hasher.jsTrim("   "), "")
        XCTAssertEqual(Hasher.jsTrim(""), "")
        XCTAssertEqual(Hasher.jsTrim("\u{85}x"), "\u{85}x")
    }

    // MARK: hashDigits

    func testDigitsProduceSha256AndSha1OfTheExactString() {
        let out = Hasher.digits("919999999999")
        XCTAssertEqual(out.map(\.0), ["sha256", "sha1"])
        XCTAssertEqual(out[0].1, "5a15bf8887c41bb21f3b33a5bf1a06064711a6495cbbd97ddb92995d5df8b1b5")
        XCTAssertEqual(out[1].1, "a983675bd344456da24fde5fc32c12e15ae17157")
        XCTAssertEqual(Hasher.digits("0001234567")[0].1, "318221a629a9e10068ee3cdefeaffc7432d51977691f89804eacfa5a587c4d14")
    }

    // MARK: cleanCellno

    func testCleanCellnoStripsFormattingCharacters() {
        XCTAssertEqual(Hasher.cleanCellno("(999) 999-9999", explicitCc: nil), Hasher.Cellno(number: "9999999999", cc: nil))
        XCTAssertEqual(Hasher.cleanCellno("+91-9999999999", explicitCc: nil), Hasher.Cellno(number: "919999999999", cc: nil))
    }

    func testCleanCellnoSplitsTheCountryCodeOnTheLegacySpaceFormat() {
        XCTAssertEqual(Hasher.cleanCellno("91 9999999999", explicitCc: nil), Hasher.Cellno(number: "9999999999", cc: "91"))
        XCTAssertEqual(Hasher.cleanCellno("+91 (99999) 99999", explicitCc: nil), Hasher.Cellno(number: "9999999999", cc: "91"))
        XCTAssertEqual(Hasher.cleanCellno("+1234 5", explicitCc: nil), Hasher.Cellno(number: "5", cc: "1234"))
        XCTAssertEqual(Hasher.cleanCellno(" 44  7700 900123", explicitCc: nil), Hasher.Cellno(number: "7700900123", cc: "44"))
    }

    func testCleanCellnoExplicitCcWinsOverTheSpaceFormat() {
        XCTAssertEqual(Hasher.cleanCellno("91 9999999999", explicitCc: "1"), Hasher.Cellno(number: "9999999999", cc: "1"))
        XCTAssertEqual(Hasher.cleanCellno("9999999999", explicitCc: "91"), Hasher.Cellno(number: "9999999999", cc: "91"))
        XCTAssertEqual(Hasher.cleanCellno("9999999999", explicitCc: "+91"), Hasher.Cellno(number: "9999999999", cc: "91"))
    }

    func testCleanCellnoEdgeCases() {
        // A 5-digit token is not a cc; the whole string is the number.
        XCTAssertEqual(Hasher.cleanCellno("+12345 6", explicitCc: nil), Hasher.Cellno(number: "123456", cc: nil))
        // Empty / digitless explicit cc → no cc.
        XCTAssertEqual(Hasher.cleanCellno("9999999999", explicitCc: ""), Hasher.Cellno(number: "9999999999", cc: nil))
        XCTAssertEqual(Hasher.cleanCellno("9999999999", explicitCc: "+-"), Hasher.Cellno(number: "9999999999", cc: nil))
        // No digits at all.
        XCTAssertEqual(Hasher.cleanCellno("abc", explicitCc: nil), Hasher.Cellno(number: "", cc: nil))
        XCTAssertEqual(Hasher.cleanCellno("", explicitCc: nil), Hasher.Cellno(number: "", cc: nil))
        XCTAssertEqual(Hasher.cleanCellno("   ", explicitCc: nil), Hasher.Cellno(number: "", cc: nil))
        // Non-ASCII digits are not \d.
        XCTAssertEqual(Hasher.cleanCellno("٩٩٩ 123", explicitCc: nil), Hasher.Cellno(number: "123", cc: nil))
        // Leading whitespace is trimmed before the split.
        XCTAssertEqual(Hasher.cleanCellno(" 91 9", explicitCc: nil), Hasher.Cellno(number: "9", cc: "91"))
    }
}
