import XCTest
@testable import ZeotapSDK

/// Mirror of the `translateTCData` half of `sdk/js/src/tcf.test.ts`, plus the bit-string decoding
/// the IAB TCF-for-Apps defaults require.
final class TcfTranslatorTests: XCTestCase {
    private func purposes(_ ids: Int...) -> [Int: Bool] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, true) })
    }

    private func options(_ build: (inout ConsentOptions) -> Void = { _ in }) -> ConsentOptions {
        var options = ConsentOptions()
        build(&options)
        return options
    }

    private func translate(_ purposes: [Int: Bool]?, vendors: [Int: Bool]? = [:], _ build: (inout ConsentOptions) -> Void = { _ in }) -> ConsentSignals {
        TcfTranslator.translate(purposeConsents: purposes, vendorConsents: vendors, options: options(build))
    }

    // MARK: translateTCData

    func testTrackEitherDefaultPurposeGroupGrants() {
        XCTAssertTrue(translate(purposes(1, 3, 4)).track)
        XCTAssertTrue(translate(purposes(1, 5, 6)).track)
        XCTAssertFalse(translate(purposes(1, 3)).track)
        XCTAssertFalse(translate(purposes(3, 4, 5, 6)).track, "purpose 1 is in both groups")
    }

    func testTrackCustomPurposesMustAllBeConsented() {
        let data = purposes(1, 2)
        XCTAssertTrue(translate(data) { $0.purposesForTracking = [1, 2] }.track)
        XCTAssertFalse(translate(data) { $0.purposesForTracking = [1, 2, 3] }.track)
        XCTAssertFalse(translate(data) { $0.purposesForTracking = [] }.track, "[] means defaults, not 'no purposes'")
        XCTAssertTrue(translate(purposes(1, 3, 4)) { $0.purposesForTracking = [] }.track)
    }

    func testTrackCheckVendorConsentRequiresTheZeotapVendor() {
        XCTAssertFalse(translate(purposes(1, 3, 4)) { $0.checkVendorConsent = true }.track)
        XCTAssertTrue(translate(purposes(1, 3, 4), vendors: [TcfTranslator.zeotapGVLId: true]) { $0.checkVendorConsent = true }.track)
        XCTAssertTrue(translate(purposes(1, 3, 4), vendors: [TcfTranslator.zeotapGVLOldId: true]) { $0.checkVendorConsent = true }.track)
        XCTAssertFalse(translate(purposes(1, 3, 4), vendors: nil) { $0.checkVendorConsent = true }.track, "no vendor map at all")
        XCTAssertTrue(translate(purposes(1, 3, 4), vendors: nil).track, "vendor irrelevant to track when the check is off")
    }

    func testIdentifyAlwaysRequiresZeotapVendorConsentPlusPurposes1And9() {
        XCTAssertFalse(translate(purposes(1, 9)).identify)
        XCTAssertTrue(translate(purposes(1, 9), vendors: [TcfTranslator.zeotapGVLId: true]).identify)
        XCTAssertTrue(translate(purposes(1, 9), vendors: [TcfTranslator.zeotapGVLOldId: true]).identify, "legacy GVL id still honoured")
        XCTAssertFalse(translate(purposes(1), vendors: [TcfTranslator.zeotapGVLId: true]).identify)
        XCTAssertFalse(translate(purposes(1, 9), vendors: [TcfTranslator.zeotapGVLId: false, 42: true]).identify)
        XCTAssertTrue(translate(purposes(1), vendors: [TcfTranslator.zeotapGVLId: true]) { $0.purposesForIdentifying = [1] }.identify)
    }

    func testCookieSyncDefaultGroupsOrCustomPurposes() {
        XCTAssertTrue(translate(purposes(1, 5, 6)).cookieSync)
        XCTAssertTrue(translate(purposes(1)) { $0.purposesForCookieSync = [1] }.cookieSync)
        XCTAssertFalse(translate(purposes(2)).cookieSync)
        XCTAssertFalse(translate(purposes(1, 3, 4)) { $0.purposesForCookieSync = [7] }.cookieSync)
    }

    func testNoPurposeConsentsAtAllDeniesEverything() {
        XCTAssertEqual(translate(nil, vendors: [TcfTranslator.zeotapGVLId: true]), .uniform(false))
        XCTAssertEqual(translate([:], vendors: [TcfTranslator.zeotapGVLId: true]), .uniform(false), "present but empty map → all purposes false")
    }

    func testConstants() {
        XCTAssertEqual(TcfTranslator.zeotapGVLId, 1469)
        XCTAssertEqual(TcfTranslator.zeotapGVLOldId, 301)
        XCTAssertEqual(TcfTranslator.defaultTrackingPurposes, [[1, 3, 4], [1, 5, 6]])
        XCTAssertEqual(TcfTranslator.defaultIdentifyingPurposes, [1, 9])
        XCTAssertEqual(TcfTranslator.defaultCookieSyncPurposes, [[1, 3, 4], [1, 5, 6]])
    }

    // MARK: bit strings

    func testBitStringToConsentsIs1Based() {
        XCTAssertNil(TcfTranslator.bitStringToConsents(nil))
        XCTAssertEqual(TcfTranslator.bitStringToConsents(""), [:])
        XCTAssertEqual(TcfTranslator.bitStringToConsents("101"), [1: true, 2: false, 3: true])
        XCTAssertEqual(TcfTranslator.bitStringToConsents("0x1")?[2], false, "anything but '1' is false")
    }

    func testTranslateTcDataDecodesTheBitStrings() {
        let vendors = String(repeating: "0", count: TcfTranslator.zeotapGVLId - 1) + "1"
        let data = TcData(cmpSdkId: 7, gdprApplies: true, tcString: "TC", purposeConsents: "101100001", vendorConsents: vendors)
        XCTAssertEqual(TcfTranslator.translate(data, options: options()), .uniform(true))

        let truncated = TcData(cmpSdkId: 7, gdprApplies: true, tcString: "TC", purposeConsents: "101100001", vendorConsents: String(repeating: "0", count: 300) + "1")
        XCTAssertEqual(TcfTranslator.translate(truncated, options: options()), ConsentSignals(track: true, identify: true, cookieSync: true), "bit 301 = legacy Zeotap id")

        let noVendorString = TcData(cmpSdkId: 7, gdprApplies: true, tcString: "TC", purposeConsents: "101100001", vendorConsents: nil)
        XCTAssertEqual(TcfTranslator.translate(noVendorString, options: options()), ConsentSignals(track: true, identify: false, cookieSync: true))

        XCTAssertEqual(
            TcfTranslator.translate(TcData(cmpSdkId: 7, gdprApplies: true, tcString: "TC", purposeConsents: nil, vendorConsents: vendors), options: options()),
            .uniform(false)
        )
    }

    func testTcDataCmpPresent() {
        XCTAssertFalse(TcData.empty.cmpPresent)
        XCTAssertTrue(TcData(cmpSdkId: 7).cmpPresent)
        XCTAssertTrue(TcData(gdprApplies: false).cmpPresent)
        XCTAssertTrue(TcData(tcString: "TC").cmpPresent)
        XCTAssertFalse(TcData(purposeConsents: "1", vendorConsents: "1").cmpPresent, "consent strings alone do not prove a CMP")
    }
}
