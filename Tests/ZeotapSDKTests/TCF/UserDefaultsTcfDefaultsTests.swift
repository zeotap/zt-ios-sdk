import XCTest
@testable import ZeotapSDK

/// `UserDefaultsTcfDefaults` over an isolated `UserDefaults` suite: the IABTCF_* read mapping and
/// (where the Objective-C runtime provides KVO) change observation.
final class UserDefaultsTcfDefaultsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "com.zeotap.sdk.tests.tcf.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testAbsentKeysReadAsEmpty() throws {
        let reader = UserDefaultsTcfDefaults(defaults: try makeDefaults())
        let data = reader.read()
        XCTAssertEqual(data, .empty)
        XCTAssertFalse(data.cmpPresent)
        XCTAssertNil(data.gdprApplies, "absent gdprApplies is nil, not false")
    }

    func testReadsEveryIabtcfKey() throws {
        let defaults = try makeDefaults()
        defaults.set(7, forKey: UserDefaultsTcfDefaults.keyCmpSdkId)
        defaults.set(1, forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        defaults.set("TC-STRING", forKey: UserDefaultsTcfDefaults.keyTcString)
        defaults.set("101100001", forKey: UserDefaultsTcfDefaults.keyPurposeConsents)
        defaults.set("0001", forKey: UserDefaultsTcfDefaults.keyVendorConsents)

        let data = UserDefaultsTcfDefaults(defaults: defaults).read()
        XCTAssertEqual(data, TcData(cmpSdkId: 7, gdprApplies: true, tcString: "TC-STRING", purposeConsents: "101100001", vendorConsents: "0001"))
        XCTAssertTrue(data.cmpPresent)
    }

    func testGdprAppliesMapping() throws {
        let defaults = try makeDefaults()
        let reader = UserDefaultsTcfDefaults(defaults: defaults)
        defaults.set(0, forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertEqual(reader.read().gdprApplies, false)
        defaults.set(1, forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertEqual(reader.read().gdprApplies, true)
        // IAB mandates Int; a CMP that wrote a string is tolerated.
        defaults.set("1", forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertEqual(reader.read().gdprApplies, true)
        defaults.set(" 0 ", forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertEqual(reader.read().gdprApplies, false)
        defaults.set("maybe", forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertNil(reader.read().gdprApplies)
        defaults.removeObject(forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertNil(reader.read().gdprApplies)
    }

    func testCmpSdkIdAcceptsIntOrNumericString() throws {
        let defaults = try makeDefaults()
        let reader = UserDefaultsTcfDefaults(defaults: defaults)
        defaults.set("42", forKey: UserDefaultsTcfDefaults.keyCmpSdkId)
        XCTAssertEqual(reader.read().cmpSdkId, 42)
        defaults.set(NSNumber(value: 43), forKey: UserDefaultsTcfDefaults.keyCmpSdkId)
        XCTAssertEqual(reader.read().cmpSdkId, 43)
        defaults.set(["not": "a number"], forKey: UserDefaultsTcfDefaults.keyCmpSdkId)
        XCTAssertNil(reader.read().cmpSdkId)
    }

    func testNonStringConsentValuesReadAsAbsent() throws {
        let defaults = try makeDefaults()
        defaults.set(12345, forKey: UserDefaultsTcfDefaults.keyTcString)
        defaults.set(true, forKey: UserDefaultsTcfDefaults.keyPurposeConsents)
        let data = UserDefaultsTcfDefaults(defaults: defaults).read()
        XCTAssertNil(data.tcString)
        XCTAssertNil(data.purposeConsents)
        XCTAssertFalse(data.cmpPresent)
    }

    func testCmpPresentFromAnySignalKey() throws {
        let defaults = try makeDefaults()
        let reader = UserDefaultsTcfDefaults(defaults: defaults)
        defaults.set(0, forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        XCTAssertTrue(reader.read().cmpPresent, "gdprApplies=0 alone proves a CMP wrote the defaults")
        defaults.removeObject(forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        defaults.set("TC", forKey: UserDefaultsTcfDefaults.keyTcString)
        XCTAssertTrue(reader.read().cmpPresent)
    }

    func testObservedKeysCoverTheWholeIabtcfSet() {
        XCTAssertEqual(UserDefaultsTcfDefaults.observedKeys, ["IABTCF_CmpSdkID", "IABTCF_gdprApplies", "IABTCF_TCString", "IABTCF_PurposeConsents", "IABTCF_VendorConsents"])
    }

    #if canImport(ObjectiveC)
    func testObserveFiresOnWritesUntilCancelled() throws {
        let defaults = try makeDefaults()
        let reader = UserDefaultsTcfDefaults(defaults: defaults)
        let lock = NSLock()
        var calls = 0
        let fired = expectation(description: "change observed")
        fired.assertForOverFulfill = false // KVO + didChangeNotification may both report one write
        let token = reader.observe {
            lock.lock()
            calls += 1
            lock.unlock()
            fired.fulfill()
        }

        defaults.set("TC-1", forKey: UserDefaultsTcfDefaults.keyTcString)
        wait(for: [fired], timeout: 2)
        lock.lock()
        let afterFirstWrite = calls
        lock.unlock()
        XCTAssertGreaterThanOrEqual(afterFirstWrite, 1)

        token.cancel()
        defaults.set("TC-2", forKey: UserDefaultsTcfDefaults.keyTcString)
        defaults.set(1, forKey: UserDefaultsTcfDefaults.keyGdprApplies)
        lock.lock()
        let afterCancel = calls
        lock.unlock()
        XCTAssertEqual(afterCancel, afterFirstWrite, "no callbacks after cancel")
        token.cancel() // idempotent
    }
    #endif
}
