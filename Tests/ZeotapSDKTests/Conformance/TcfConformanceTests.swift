import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/tcf.vectors.json — `translateTCData` driven from the IAB TCF-for-Apps bit
/// strings (`input.iabtcf.*`, `null` = key absent). Cases tagged `bit-string-truncated` carry
/// `expectedFromBits`, the answer a bit-string decoder must reach (vendor 1469 beyond the string → false).
final class TcfConformanceTests: XCTestCase {
    func testTcfVectors() {
        let cases = VectorLoader.cases("tcf")
        XCTAssertFalse(cases.isEmpty, "no tcf vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "tcf/\(testCase.id)") { _ in
                run(testCase.id, input: testCase.input, expected: testCase.raw["expectedFromBits"] ?? testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) {
        guard let iabtcf = input["iabtcf"] else {
            XCTFail("\(id): no iabtcf block")
            return
        }
        let options = TcfConformanceTests.options(from: input["options"] ?? .object([]))
        let purposeBits = iabtcf["IABTCF_PurposeConsents"]?.stringValue
        let vendorBits = iabtcf["IABTCF_VendorConsents"]?.stringValue

        let fromMaps = TcfTranslator.translate(
            purposeConsents: TcfTranslator.bitStringToConsents(purposeBits),
            vendorConsents: TcfTranslator.bitStringToConsents(vendorBits),
            options: options
        )
        assertJSONEqual(ConsentState.signalsToJSON(fromMaps), expected, "\(id): translate(purposeConsents:vendorConsents:)")

        // The TcData entry point the integration uses must agree.
        let tcData = TcData(cmpSdkId: 1, gdprApplies: true, tcString: "TC", purposeConsents: purposeBits, vendorConsents: vendorBits)
        assertJSONEqual(ConsentState.signalsToJSON(TcfTranslator.translate(tcData, options: options)), expected, "\(id): translate(TcData)")
    }

    static func options(from json: JSONValue) -> ConsentOptions {
        var options = ConsentOptions()
        options.purposesForTracking = ints(json["purposesForTracking"])
        options.purposesForIdentifying = ints(json["purposesForIdentifying"])
        options.purposesForCookieSync = ints(json["purposesForCookieSync"])
        options.checkVendorConsent = json["checkVendorConsent"]?.boolValue ?? false
        return options
    }

    private static func ints(_ value: JSONValue?) -> [Int] {
        (value?.arrayValue ?? []).compactMap { $0.intValue.map { Int($0) } }
    }
}
