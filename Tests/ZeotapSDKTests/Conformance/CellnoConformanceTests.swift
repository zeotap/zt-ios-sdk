import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/cellno.vectors.json — `cleanCellno`: ECMAScript trim, ASCII-digit
/// stripping, the legacy `"<cc> <number>"` split and explicit-cc precedence. `cc` is ABSENT when no
/// country code was recognised.
final class CellnoConformanceTests: XCTestCase {
    func testCellnoVectors() {
        let cases = VectorLoader.cases("cellno")
        XCTAssertFalse(cases.isEmpty, "no cellno vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "cellno/\(testCase.id)") { _ in
                let raw = testCase.input["raw"]?.stringValue ?? ""
                let explicitCc = testCase.input["explicitCc"]?.stringValue
                let result = Hasher.cleanCellno(raw, explicitCc: explicitCc)
                var pairs: [(String, JSONValue)] = [("number", .string(result.number))]
                if let cc = result.cc { pairs.append(("cc", .string(cc))) }
                assertJSONEqual(.object(pairs), testCase.expected, "cellno/\(testCase.id)")
            }
        }
    }
}
