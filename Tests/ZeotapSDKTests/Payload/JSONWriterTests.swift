import XCTest
@testable import ZeotapSDK

final class JSONWriterTests: XCTestCase {
    func testWritesCompactOrderedJSONLikeStringify() {
        let value = JSONValue.object([
            ("s", .string("a\"b\\c\n\t\u{01}é🙂/")),
            ("i", .int(42)),
            ("d", .double(2.5)),
            ("t", .bool(true)),
            ("n", .null),
            ("a", .array([.int(1), .string("x"), .null])),
            ("o", .object([("z", .int(1)), ("a", .int(2))]))
        ])
        XCTAssertEqual(JSONWriter.string(value), "{\"s\":\"a\\\"b\\\\c\\n\\t\\u0001é🙂/\",\"i\":42,\"d\":2.5,\"t\":true,\"n\":null,\"a\":[1,\"x\",null],\"o\":{\"z\":1,\"a\":2}}")
    }

    func testSubscriptSetKeepsPositionAndAppendsNewKeys() {
        var value = JSONValue.object([("a", .int(1)), ("b", .int(2))])
        value["a"] = .int(9)
        value["c"] = .int(3)
        XCTAssertEqual(value.objectKeys, ["a", "b", "c"])
        XCTAssertEqual(value["a"], .int(9))
        value["b"] = nil
        XCTAssertEqual(value.objectKeys, ["a", "c"])
    }

    func testEqualityIsOrderSensitiveForObjectsAndNumericAcrossIntDouble() {
        XCTAssertNotEqual(JSONValue.object([("a", .int(1)), ("b", .int(2))]), JSONValue.object([("b", .int(2)), ("a", .int(1))]))
        XCTAssertEqual(JSONValue.int(2), JSONValue.double(2))
    }

    func testMapperNormalisesNumbersBooleansDatesAndNesting() throws {
        let date = Date(timeIntervalSince1970: 1_768_472_430.123)
        let json = try JSONMapper.fromDictionary(["b": true, "i": 3, "d": 1.0, "f": 2.5, "n": NSNull(), "date": date, "nested": ["z": [1, 2.5]], "neg": -0.0])
        XCTAssertEqual(JSONWriter.string(json), "{\"b\":true,\"d\":1,\"date\":\"2026-01-15T10:20:30.123Z\",\"f\":2.5,\"i\":3,\"n\":null,\"neg\":0,\"nested\":{\"z\":[1,2.5]}}")
    }

    func testMapperRejectsUnsupportedValues() {
        XCTAssertThrowsError(try JSONMapper.fromDictionary(["bad": NSObject()])) { error in
            XCTAssertEqual(error as? ZeotapError, .invalidProperties(key: "bad"))
        }
    }
}

final class JSNumberTests: XCTestCase {
    func testPlainDecimals() {
        XCTAssertEqual(JSNumber.format(2.5), "2.5")
        XCTAssertEqual(JSNumber.format(0.1), "0.1")
        XCTAssertEqual(JSNumber.format(99.99), "99.99")
        XCTAssertEqual(JSNumber.format(-3.75), "-3.75")
        XCTAssertEqual(JSNumber.format(12_345_678.9), "12345678.9")
        XCTAssertEqual(JSNumber.format(0.000001), "0.000001")
        XCTAssertEqual(JSNumber.format(0.0000001), "1e-7")
        XCTAssertEqual(JSNumber.format(1.5e-7), "1.5e-7")
    }

    func testLargeMagnitudesSwitchToExponentFormAt1e21() {
        XCTAssertEqual(JSNumber.format(1e21), "1e+21")
        XCTAssertEqual(JSNumber.format(1.5e21), "1.5e+21")
        XCTAssertEqual(JSNumber.format(1e20), "100000000000000000000")
        XCTAssertEqual(JSNumber.format(9_007_199_254_740_992), "9007199254740992")
        XCTAssertEqual(JSNumber.format(-1e21), "-1e+21")
        XCTAssertEqual(JSNumber.format(1), "1")
        XCTAssertEqual(JSNumber.format(0), "0")
    }
}

final class Iso8601Tests: XCTestCase {
    func testFormatsUTCWithThreeFractionalDigits() {
        XCTAssertEqual(Iso8601.format(epochMs: 1_768_472_430_123), "2026-01-15T10:20:30.123Z")
        XCTAssertEqual(Iso8601.format(epochMs: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(Iso8601.format(epochMs: 1_768_472_430_000), "2026-01-15T10:20:30.000Z")
        XCTAssertEqual(Iso8601.format(epochMs: 4_102_444_799_999), "2099-12-31T23:59:59.999Z")
    }

    func testSystemClockAndIdGeneratorShapes() {
        XCTAssertGreaterThan(SystemClock().nowMs(), 1_700_000_000_000)
        let id = SystemIdGenerator().uuid()
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression), id)
    }
}

final class VersionTests: XCTestCase {
    func testGeneratedVersionMatchesTheVersionFile() throws {
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let expected = try String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(SDKVersion.current, expected, "run scripts/stamp-version.sh")
        XCTAssertNotNil(SDKVersion.current.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression))
    }

    func testConfigurationValidation() throws {
        XCTAssertThrowsError(try Configuration(apiHost: "").validated())
        XCTAssertThrowsError(try Configuration(apiHost: "ftp://x").validated())
        var bad = Configuration(apiHost: "https://x.example")
        bad.flushAt = 0
        XCTAssertThrowsError(try bad.validated())
        let ok = try Configuration(apiHost: "https://x.example/").validated()
        XCTAssertEqual(ok.apiHost, "https://x.example")
        XCTAssertEqual(ok.consent.resolvedCmp, .none)
        var gated = Configuration(apiHost: "https://x.example")
        gated.consent.require = true
        XCTAssertEqual(gated.consent.resolvedCmp, .auto)
        XCTAssertTrue(gated.consent.gatingActive)
        var partial = Configuration(apiHost: "https://x.example")
        partial.integration = IntegrationMeta(name: "only", version: "")
        XCTAssertNil(partial.integration)
        XCTAssertThrowsError(try Analytics(writeKey: " ", configuration: Configuration(apiHost: "https://x.example"))) { error in
            XCTAssertEqual(error as? ZeotapError, .missingWriteKey)
        }
    }
}
