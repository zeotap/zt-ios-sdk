import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/user-identities.test.ts` — raw hashing shapes, pre-hashed regrouping,
/// persistence, unset/clear. (The web's insecure-context drop has no native equivalent: CryptoKit /
/// swift-crypto are always available.)
final class UserIdentityManagerTests: XCTestCase {
    private let keys = Keys(namespace: "zeotap")
    private let sha256Lower = "b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514"

    private func make(_ storage: InMemoryStore = InMemoryStore(), logger: RecordingLogger = RecordingLogger()) -> UserIdentityManager {
        UserIdentityManager(keys: keys, storage: storage, logger: logger)
    }

    // MARK: raw input

    func testHashesEmailIntoThe4VariantMatrix() throws {
        let mgr = make()
        mgr.setIdentities([("email", "User@Example.com")], hashed: false)
        let email = try XCTUnwrap(mgr.get()?["email"])
        XCTAssertEqual(email["sha256_lowercase"], .string(sha256Lower))
        XCTAssertEqual(email.objectKeys.sorted(), ["sha1_lowercase", "sha1_uppercase", "sha256_lowercase", "sha256_uppercase"])
        XCTAssertEqual(email.objectKeys, ["sha256_lowercase", "sha256_uppercase", "sha1_lowercase", "sha1_uppercase"], "contractual key order")
    }

    func testHashesCellnoAndDerivesE164WhenTheCcIsKnown() throws {
        let mgr = make()
        mgr.setIdentities([("cellno", "91 99999-99999")], hashed: false)
        let ids = try XCTUnwrap(mgr.get())
        XCTAssertEqual(ids["cellno"]?["sha256"], .string(Hasher.sha256Hex("9999999999")))
        XCTAssertEqual(ids["cellno_e164"]?["sha256"], .string(Hasher.sha256Hex("919999999999")))
        XCTAssertEqual(ids.objectKeys, ["cellno", "cellno_e164"])
    }

    func testUsesTheCellnoCcFieldForE164Derivation() {
        let mgr = make()
        mgr.setIdentities([("cellno", "9999999999"), ("cellno_cc", "91")], hashed: false)
        XCTAssertEqual(mgr.get()?["cellno_e164"]?["sha256"], .string(Hasher.sha256Hex("919999999999")))
        XCTAssertNil(mgr.get()?["cellno_cc"], "cellno_cc is consumed, never emitted")
    }

    func testCellnoCcListedBeforeCellnoStillApplies() {
        let mgr = make()
        mgr.setIdentities([("cellno_cc", "91"), ("cellno", "9999999999")], hashed: false)
        XCTAssertEqual(mgr.get()?["cellno_e164"]?["sha256"], .string(Hasher.sha256Hex("919999999999")))
    }

    func testNoCcMeansNoE164() {
        let mgr = make()
        mgr.setIdentities([("cellno", "9999999999")], hashed: false)
        XCTAssertNotNil(mgr.get()?["cellno"])
        XCTAssertNil(mgr.get()?["cellno_e164"])
    }

    func testCellnoWithoutDigitsAndCcWithoutCellnoEmitNothing() {
        let mgr = make()
        mgr.setIdentities([("cellno", "abc")], hashed: false)
        XCTAssertNil(mgr.get())
        mgr.setIdentities([("cellno_cc", "91")], hashed: false)
        XCTAssertNil(mgr.get())
    }

    func testFpuidAndCustomKeysPassThroughRaw() {
        let mgr = make()
        mgr.setIdentities([("fpuid", "fp-1"), ("crmId", "crm-9")], hashed: false)
        assertJSONEqual(mgr.get(), .object([("fpuid", .string("fp-1")), ("crmId", .string("crm-9"))]), "passthrough")
    }

    func testMergesAcrossCallsAndSkipsEmptyValues() {
        let mgr = make()
        mgr.setIdentities([("fpuid", "fp-1")], hashed: false)
        mgr.setIdentities([("crmId", "crm-9"), ("email", ""), ("loginid", nil)], hashed: false)
        assertJSONEqual(mgr.get(), .object([("fpuid", .string("fp-1")), ("crmId", .string("crm-9"))]), "merge")
    }

    func testOverwritingAKeyKeepsItsPosition() {
        let mgr = make()
        mgr.setIdentities([("email", "a@b.com"), ("fpuid", "fp-1")], hashed: false)
        mgr.setIdentities([("email", "c@d.com")], hashed: false)
        XCTAssertEqual(mgr.get()?.objectKeys, ["email", "fpuid"])
        XCTAssertEqual(mgr.get()?["email"]?["sha256_lowercase"], .string(Hasher.sha256Hex("c@d.com")))
    }

    // MARK: pre-hashed input

    func testRegroupsFlatLegacyKeys() {
        let mgr = make()
        mgr.setIdentities([
            ("email_sha256_lowercase", "aa"),
            ("email_md5_uppercase", "bb"),
            ("cellno_sha256", "cc"),
            ("cellno_e164_sha1", "dd"),
            ("fpuid", "fp-1")
        ], hashed: true)
        assertJSONEqual(mgr.get(), .object([
            ("email", .object([("sha256_lowercase", .string("aa")), ("md5_uppercase", .string("bb"))])),
            ("cellno", .object([("sha256", .string("cc"))])),
            ("cellno_e164", .object([("sha1", .string("dd"))])),
            ("fpuid", .string("fp-1"))
        ]), "regroup")
    }

    func testHashedModeStoresUnmatchedKeysRawAndReplacesAnExistingGroup() {
        let mgr = make()
        mgr.setIdentities([("email", "a@b.com")], hashed: false)
        mgr.setIdentities([("email_md5_lowercase", "emd5l"), ("loginid_sha1_lowercase", "l1l"), ("cellno_with_country_code_sha256", "cwc"), ("crm", "raw")], hashed: true)
        let ids = mgr.get()
        // The web merge is a shallow `{...existing, ...resolved}`: the new group REPLACES the old one
        // for the same base key (it keeps its position), it is not merged into it.
        XCTAssertEqual(ids?["email"], .object([("md5_lowercase", .string("emd5l"))]))
        XCTAssertEqual(ids?.objectKeys, ["email", "loginid", "cellno_with_country_code", "crm"])
        XCTAssertEqual(ids?["loginid"], .object([("sha1_lowercase", .string("l1l"))]))
        XCTAssertEqual(ids?["cellno_with_country_code"], .object([("sha256", .string("cwc"))]))
        XCTAssertEqual(ids?["crm"], .string("raw"))
    }

    func testHashedKeyMatchers() {
        XCTAssertEqual(UserIdentityManager.matchHashedCaseKey("email_sha256_lowercase").map { [$0.0, $0.1] }, ["email", "sha256_lowercase"])
        XCTAssertEqual(UserIdentityManager.matchHashedCaseKey("loginid_md5_uppercase").map { [$0.0, $0.1] }, ["loginid", "md5_uppercase"])
        XCTAssertNil(UserIdentityManager.matchHashedCaseKey("cellno_sha256_lowercase"))
        XCTAssertNil(UserIdentityManager.matchHashedCaseKey("email_sha512_lowercase"))
        XCTAssertNil(UserIdentityManager.matchHashedCaseKey("email_sha256"))
        XCTAssertEqual(UserIdentityManager.matchHashedDigitKey("cellno_e164_sha1").map { [$0.0, $0.1] }, ["cellno_e164", "sha1"])
        XCTAssertEqual(UserIdentityManager.matchHashedDigitKey("cellno_without_country_code_md5").map { [$0.0, $0.1] }, ["cellno_without_country_code", "md5"])
        XCTAssertNil(UserIdentityManager.matchHashedDigitKey("email_sha256"))
        XCTAssertNil(UserIdentityManager.matchHashedDigitKey("cellno"))
    }

    // MARK: persistence & lifecycle

    func testPersistsAndReloadsInANewInstance() {
        let storage = InMemoryStore()
        let mgr = make(storage)
        mgr.setIdentities([("fpuid", "fp-1")], hashed: false)
        XCTAssertEqual(storage.get(keys.userIdentities), "{\"fpuid\":\"fp-1\"}")

        let reloaded = make(storage)
        assertJSONEqual(reloaded.get(), .object([("fpuid", .string("fp-1"))]), "reloaded")
    }

    func testReloadKeepsThePersistedKeyOrder() {
        let storage = InMemoryStore()
        make(storage).setIdentities([("fpuid", "fp-1"), ("email", "a@b.com"), ("custom", "c")], hashed: false)
        XCTAssertEqual(make(storage).get()?.objectKeys, ["fpuid", "email", "custom"])
    }

    func testUnsetRemovesSpecificKeysAndUnsetNilClearsAll() {
        let storage = InMemoryStore()
        let mgr = make(storage)
        mgr.setIdentities([("fpuid", "fp-1"), ("crmId", "crm-9")], hashed: false)

        mgr.unset(["fpuid", "missing"])
        assertJSONEqual(mgr.get(), .object([("crmId", .string("crm-9"))]), "after unset")
        XCTAssertEqual(storage.get(keys.userIdentities), "{\"crmId\":\"crm-9\"}")

        mgr.unset(nil)
        XCTAssertNil(mgr.get())
        XCTAssertNil(storage.get(keys.userIdentities))
    }

    func testUnsetEmptyArrayAndClearRemoveEverything() {
        let storage = InMemoryStore()
        let mgr = make(storage)
        mgr.setIdentities([("fpuid", "fp-1")], hashed: false)
        mgr.unset([])
        XCTAssertNil(mgr.get())
        XCTAssertNil(storage.get(keys.userIdentities))

        mgr.setIdentities([("fpuid", "fp-2")], hashed: false)
        mgr.clear()
        XCTAssertNil(mgr.get())
        XCTAssertNil(storage.get(keys.userIdentities))
    }

    func testCorruptOrMalformedRecordIsIgnoredWithAWarning() {
        let logger = RecordingLogger()
        let corrupt = InMemoryStore([keys.userIdentities: "{not json"])
        XCTAssertNil(make(corrupt, logger: logger).get())
        XCTAssertEqual(logger.warns, ["[SDK] Ignoring corrupt user identities record"])

        let malformed = InMemoryStore([keys.userIdentities: "[1,2]"])
        XCTAssertNil(make(malformed, logger: logger).get())
        XCTAssertEqual(logger.warns.last, "[SDK] Ignoring malformed user identities record")
        // Identity values never reach the log.
        XCTAssertFalse(logger.warns.joined().contains("not json"))
    }
}
