import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/consent-persistence.vectors.json — two shapes:
/// - `saves`: a `FakeClock` at `nowMs` (+ `atMs` per save); after each save the `writes` delta on the
///   `InMemoryStore`, the main / side records structurally AND byte-exact (`mainJson`/`tcfJson`), then
///   `loaded` from the same persistence.
/// - `storage`: seeded records; `result` of `load()` and the exact `storageAfter` contents.
final class ConsentPersistenceConformanceTests: XCTestCase {
    func testConsentPersistenceVectors() {
        let cases = VectorLoader.cases("consent-persistence")
        XCTAssertFalse(cases.isEmpty, "no consent-persistence vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "consent-persistence/\(testCase.id)") { _ in
                run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) {
        let namespace = input["namespace"]?.stringValue ?? "zeotap"
        let keys = Keys(namespace: namespace)
        let nowMs = input["nowMs"]?.intValue ?? 0
        let expiryDays = Int(input["expiryDays"]?.intValue ?? 365)
        let clock = FakeClock(nowMs: nowMs)
        let storage = InMemoryStore(input["storage"]?.stringDictionary ?? [:])
        let persistence = ConsentPersistence(keys: keys, storage: storage, expiryDays: expiryDays, clock: clock)

        if let saves = input["saves"]?.arrayValue {
            let expectedSaves = expected["afterEachSave"]?.arrayValue ?? []
            XCTAssertEqual(saves.count, expectedSaves.count, "\(id): save count")
            for (index, save) in saves.enumerated() {
                clock.now = nowMs + (save["atMs"]?.intValue ?? 0)
                guard let resolution = ConsentPersistenceConformanceTests.resolution(from: save["resolution"]) else {
                    XCTFail("\(id)[\(index)]: bad resolution")
                    return
                }
                let writesBefore = storage.writes
                persistence.save(resolution)
                guard index < expectedSaves.count else { continue }
                let expectedSave = expectedSaves[index]
                XCTAssertEqual(Int64(storage.writes - writesBefore), expectedSave["writes"]?.intValue, "\(id)[\(index)]: writes delta")
                assertRecord(storage.get(keys.consent), structural: expectedSave["main"], exact: expectedSave["mainJson"], "\(id)[\(index)]: main record")
                assertRecord(storage.get(keys.consentTcf), structural: expectedSave["tcf"], exact: expectedSave["tcfJson"], "\(id)[\(index)]: tcf side record")
            }
            if let loaded = expected["loaded"] {
                assertJSONEquivalent(persistence.load().map(ConsentPersistenceConformanceTests.json) ?? .null, loaded, "\(id): loaded")
            }
        } else {
            let result = persistence.load()
            assertJSONEquivalent(result.map(ConsentPersistenceConformanceTests.json) ?? .null, expected["result"] ?? .null, "\(id): result")
            if let storageAfter = expected["storageAfter"] {
                XCTAssertEqual(storage.snapshot(), storageAfter.stringDictionary, "\(id): storageAfter")
            }
        }
    }

    private func assertRecord(_ raw: String?, structural: JSONValue?, exact: JSONValue?, _ context: String) {
        if let structural, !structural.isNull {
            assertJSONEqual(raw.flatMap(JSONParser.parseOrdered), structural, "\(context) (structural)")
        } else {
            XCTAssertNil(raw, "\(context): key should be absent")
        }
        if let exact, !exact.isNull {
            XCTAssertEqual(raw, exact.stringValue, "\(context) (byte-exact)")
        }
    }

    /// `{signals, input?, tcfString?, gdprApplies?, source, ts}` → `ResolvedConsent`.
    static func resolution(from json: JSONValue?) -> ResolvedConsent? {
        guard let json, let signals = json["signals"].flatMap(ConsentState.signalsFromJSON),
              let source = json["source"]?.stringValue.flatMap(ConsentSource.init(rawValue:)) else { return nil }
        return ResolvedConsent(
            signals: signals,
            input: json["input"].flatMap(ConsentState.fromJSON),
            tcfString: json["tcfString"]?.stringValue,
            gdprApplies: json["gdprApplies"]?.boolValue,
            source: source,
            ts: json["ts"]?.intValue ?? 0
        )
    }

    /// `ResolvedConsent` in the vector shape (absent optionals omitted).
    static func json(_ resolution: ResolvedConsent) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("signals", ConsentState.signalsToJSON(resolution.signals))]
        if let input = resolution.input { pairs.append(("input", ConsentState.toJSON(input))) }
        if let gdpr = resolution.gdprApplies { pairs.append(("gdprApplies", .bool(gdpr))) }
        if let tcf = resolution.tcfString { pairs.append(("tcfString", .string(tcf))) }
        pairs.append(("source", .string(resolution.source.rawValue)))
        pairs.append(("ts", .int(resolution.ts)))
        return .object(pairs)
    }
}
