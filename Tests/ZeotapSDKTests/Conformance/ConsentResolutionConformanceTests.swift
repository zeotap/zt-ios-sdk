import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/consent-resolution.vectors.json — the `ConsentManager` precedence machine
/// replayed step by step: `accepted` (offer steps only), `resolved`, `source`, `signals`,
/// `tcfString`, `gdprApplies`, `ts`, `getConsent` and the cumulative `listenerCalls`.
final class ConsentResolutionConformanceTests: XCTestCase {
    func testConsentResolutionVectors() {
        let cases = VectorLoader.cases("consent-resolution")
        XCTAssertFalse(cases.isEmpty, "no consent-resolution vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "consent-resolution/\(testCase.id)") { _ in
                run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) {
        let clock = FakeClock(nowMs: 0)
        let manager = ConsentManager(clock: clock)
        var listenerCalls = 0
        manager.onResolve { _ in listenerCalls += 1 }

        let steps = input["steps"]?.arrayValue ?? []
        let expectedSteps = expected["afterEachStep"]?.arrayValue ?? []
        XCTAssertEqual(steps.count, expectedSteps.count, "\(id): step count")

        for (index, step) in steps.enumerated() {
            if let atMs = step["atMs"]?.intValue { clock.now = atMs }
            var accepted: Bool?
            switch step["op"]?.stringValue {
            case "setConsent":
                guard let consentInput = step["input"].flatMap(ConsentState.fromJSON) else {
                    XCTFail("\(id)[\(index)]: bad consent input")
                    return
                }
                manager.setConsent(consentInput)
            case "resolveDefault":
                manager.resolveDefault(granted: step["granted"]?.boolValue ?? false)
            case "offer":
                guard let signals = step["signals"].flatMap(ConsentState.signalsFromJSON),
                      let source = step["source"]?.stringValue.flatMap(ConsentSource.init(rawValue:)) else {
                    XCTFail("\(id)[\(index)]: bad offer")
                    return
                }
                accepted = manager.offer(ResolvedConsent(
                    signals: signals,
                    input: step["input"].flatMap(ConsentState.fromJSON),
                    tcfString: step["tcfString"]?.stringValue,
                    gdprApplies: step["gdprApplies"]?.boolValue,
                    source: source,
                    ts: step["ts"]?.intValue ?? 0
                ))
            case "clear":
                manager.clear()
            default:
                XCTFail("\(id)[\(index)]: unsupported op \(step["op"]?.stringValue ?? "nil")")
            }
            guard index < expectedSteps.count else { continue }
            let actual = snapshot(manager, accepted: accepted, listenerCalls: listenerCalls)
            assertJSONEquivalent(actual, expectedSteps[index], "\(id)[\(index)]: state after \(step["op"]?.stringValue ?? "?")")
        }
    }

    /// The vector's per-step shape; absent optionals are omitted (the vectors omit them too).
    private func snapshot(_ manager: ConsentManager, accepted: Bool?, listenerCalls: Int) -> JSONValue {
        var pairs: [(String, JSONValue)] = []
        if let accepted { pairs.append(("accepted", .bool(accepted))) }
        pairs.append(("resolved", .bool(manager.isResolved())))
        if let resolution = manager.getResolution() {
            pairs.append(("source", .string(resolution.source.rawValue)))
            pairs.append(("signals", ConsentState.signalsToJSON(resolution.signals)))
            pairs.append(("ts", .int(resolution.ts)))
            if let tcf = resolution.tcfString { pairs.append(("tcfString", .string(tcf))) }
            if let gdpr = resolution.gdprApplies { pairs.append(("gdprApplies", .bool(gdpr))) }
            XCTAssertEqual(manager.getSignals(), resolution.signals)
        } else {
            XCTAssertNil(manager.getSignals())
        }
        pairs.append(("getConsent", manager.getConsent().map(ConsentState.toJSON) ?? .null))
        pairs.append(("listenerCalls", .int(Int64(listenerCalls))))
        return .object(pairs)
    }
}
