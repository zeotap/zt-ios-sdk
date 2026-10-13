import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/identities.vectors.json — `UserIdentityManager` step scripts over an
/// `InMemoryStore`: `stored` (what attaches to `context.identities`, ordered) after each step, the
/// exact persisted string, and what a fresh manager reloads.
final class IdentitiesConformanceTests: XCTestCase {
    func testIdentitiesVectors() {
        let cases = VectorLoader.cases("identities")
        XCTAssertFalse(cases.isEmpty, "no identities vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "identities/\(testCase.id)") { _ in
                run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) {
        let namespace = input["namespace"]?.stringValue ?? "zeotap"
        let keys = Keys(namespace: namespace)
        let storage = InMemoryStore()
        let logger = RecordingLogger()
        let manager = UserIdentityManager(keys: keys, storage: storage, logger: logger)

        let steps = input["steps"]?.arrayValue ?? []
        let expectedSteps = expected["afterEachStep"]?.arrayValue ?? []
        XCTAssertEqual(steps.count, expectedSteps.count, "\(id): step count")

        for (index, step) in steps.enumerated() {
            switch step["op"]?.stringValue {
            case "set":
                // Input pairs in JSON order — the web's insertion order is observable in the persisted record.
                let pairs = (step["input"]?.objectPairs ?? []).map { ($0.0, $0.1.stringValue) }
                manager.setIdentities(pairs, hashed: step["hashed"]?.boolValue ?? false)
            case "unset":
                manager.unset(step["keys"]?.arrayValue?.compactMap(\.stringValue))
            case "clear":
                manager.clear()
            default:
                XCTFail("\(id)[\(index)]: unsupported op \(step["op"]?.stringValue ?? "nil")")
            }
            guard index < expectedSteps.count else { continue }
            let expectedStep = expectedSteps[index]
            assertJSONEqual(manager.get(), expectedStep["stored"], "\(id)[\(index)]: stored")
            let persisted = storage.get(keys.userIdentities)
            let expectedPersisted = expectedStep["persistedJson"]
            if let expectedPersisted, !expectedPersisted.isNull {
                XCTAssertEqual(persisted, expectedPersisted.stringValue, "\(id)[\(index)]: persistedJson (byte-exact)")
            } else {
                XCTAssertNil(persisted, "\(id)[\(index)]: persisted key should be absent")
            }
        }

        let reloaded = UserIdentityManager(keys: keys, storage: storage, logger: logger)
        assertJSONEqual(reloaded.get(), expected["reloaded"], "\(id): reloaded")
        XCTAssertTrue(logger.warns.isEmpty, "\(id): unexpected warnings \(logger.warns)")
    }
}
