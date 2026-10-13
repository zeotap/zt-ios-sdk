import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/consent-signals.vectors.json — `resolveSignals` over every `ConsentInput`
/// form plus the two `uniformSignals` cases. Signal key order (track, identify, cookieSync) is
/// contractual for the persisted record and is asserted through `signalsToJSON`.
final class ConsentSignalsConformanceTests: XCTestCase {
    func testConsentSignalsVectors() {
        let cases = VectorLoader.cases("consent-signals")
        XCTAssertFalse(cases.isEmpty, "no consent-signals vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "consent-signals/\(testCase.id)") { _ in
                let signals: ConsentSignals
                if let uniform = testCase.input["uniform"]?.boolValue {
                    signals = .uniform(uniform)
                } else if let input = ConsentState.fromJSON(testCase.input) {
                    signals = ConsentState.resolveSignals(input)
                    // The wire form must round-trip so the same input can ride on context.consent.
                    XCTAssertEqual(ConsentState.fromJSON(ConsentState.toJSON(input)), input, "consent-signals/\(testCase.id): toJSON/fromJSON round trip")
                } else {
                    XCTFail("consent-signals/\(testCase.id): input is not a ConsentInput")
                    return
                }
                assertJSONEqual(ConsentState.signalsToJSON(signals), testCase.expected, "consent-signals/\(testCase.id)")
            }
        }
    }
}
