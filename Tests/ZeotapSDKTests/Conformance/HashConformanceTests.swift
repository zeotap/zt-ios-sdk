import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/hash.vectors.json — digests, the 4-key case-variant matrix (trim →
/// full-Unicode casing → hash, contractual key order) and the digits pair.
final class HashConformanceTests: XCTestCase {
    func testHashVectors() {
        let cases = VectorLoader.cases("hash")
        XCTAssertFalse(cases.isEmpty, "no hash vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "hash/\(testCase.id)") { _ in
                run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) {
        let value = input["value"]?.stringValue ?? ""
        switch input["op"]?.stringValue {
        case "digestHex":
            let algorithm = input["algorithm"]?.stringValue
            let actual: String
            switch algorithm {
            case "SHA-256": actual = Hasher.sha256Hex(value)
            case "SHA-1": actual = Hasher.sha1Hex(value)
            default:
                XCTFail("\(id): unsupported algorithm \(algorithm ?? "nil")")
                return
            }
            XCTAssertEqual(actual, expected.stringValue, "\(id): digest")
        case "hashCaseVariants":
            let actual = JSONValue.object(Hasher.caseVariants(value).map { ($0.0, JSONValue.string($0.1)) })
            assertJSONEqual(actual, expected, "\(id): case variants (order matters)")
        case "hashDigits":
            let actual = JSONValue.object(Hasher.digits(value).map { ($0.0, JSONValue.string($0.1)) })
            assertJSONEqual(actual, expected, "\(id): digits")
        default:
            XCTFail("\(id): unsupported op \(input["op"]?.stringValue ?? "nil")")
        }
    }
}
