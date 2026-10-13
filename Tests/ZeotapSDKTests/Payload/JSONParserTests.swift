import XCTest
@testable import ZeotapSDK

/// `JSONParser.parseOrdered` (the hand-written `JSON.parse`) — order preservation, escapes,
/// surrogate pairs, numbers and rejection of everything `JSON.parse` rejects — plus the
/// `JSONSerialization`-backed `parse`.
final class JSONParserTests: XCTestCase {
    private func parse(_ text: String) -> JSONValue? { JSONParser.parseOrdered(text) }

    // MARK: structure

    func testPreservesObjectKeyOrder() throws {
        let value = try XCTUnwrap(parse("{\"z\":1,\"a\":2,\"m\":{\"y\":true,\"b\":null}}"))
        XCTAssertEqual(value.objectKeys, ["z", "a", "m"])
        XCTAssertEqual(value["m"]?.objectKeys, ["y", "b"])
        XCTAssertEqual(JSONWriter.string(value), "{\"z\":1,\"a\":2,\"m\":{\"y\":true,\"b\":null}}", "round-trips byte for byte")
    }

    func testDuplicateKeysKeepFirstPositionWithLastValue() throws {
        let value = try XCTUnwrap(parse("{\"a\":1,\"b\":2,\"a\":3}"))
        XCTAssertEqual(value.objectKeys, ["a", "b"])
        XCTAssertEqual(value["a"], .int(3))
    }

    func testArraysNestingAndWhitespace() throws {
        let value = try XCTUnwrap(parse(" \n\t{ \"a\" : [ 1 , [ ] , { } , \"x\" , true , false , null ] }\r\n"))
        XCTAssertEqual(value, .object([("a", .array([.int(1), .array([]), .object([]), .string("x"), .bool(true), .bool(false), .null]))]))
        XCTAssertEqual(parse("[]"), .array([]))
        XCTAssertEqual(parse("{}"), .object([]))
    }

    func testTopLevelScalarsAreAccepted() {
        XCTAssertEqual(parse("\"str\""), .string("str"))
        XCTAssertEqual(parse("42"), .int(42))
        XCTAssertEqual(parse("true"), .bool(true))
        XCTAssertEqual(parse("null"), .null)
    }

    // MARK: strings

    func testEscapes() throws {
        let value = try XCTUnwrap(parse("\"a\\\"b\\\\c\\/d\\b\\f\\n\\r\\t\\u0041\\u00e9\""))
        XCTAssertEqual(value, .string("a\"b\\c/d\u{08}\u{0C}\n\r\tA\u{E9}"))
    }

    func testUnicodeEscapeSurrogatePairs() {
        XCTAssertEqual(parse("\"\\ud83d\\ude42\""), .string("🙂"))
        XCTAssertEqual(parse("\"x\\uD83D\\uDE42y\""), .string("x🙂y"))
        // Lone surrogates cannot exist in a Swift String — replaced like TextEncoder would.
        XCTAssertEqual(parse("\"\\ud83d\""), .string("\u{FFFD}"))
        XCTAssertEqual(parse("\"\\ude42\""), .string("\u{FFFD}"))
        XCTAssertEqual(parse("\"\\ud83dabc\""), .string("\u{FFFD}abc"))
        XCTAssertEqual(parse("\"\\ud83d\\u0041\""), .string("\u{FFFD}A"), "high surrogate followed by a non-low escape")
    }

    func testRawNonAsciiPassesThrough() {
        XCTAssertEqual(parse("\"jürgen 🙂 日本\""), .string("jürgen 🙂 日本"))
    }

    func testRejectsBadStrings() {
        XCTAssertNil(parse("\"unterminated"))
        XCTAssertNil(parse("\"bad \\x escape\""))
        XCTAssertNil(parse("\"\\u12\""))
        XCTAssertNil(parse("\"\\uZZZZ\""))
        XCTAssertNil(parse("\"raw\ncontrol\""), "unescaped control characters are invalid")
        XCTAssertNil(parse("'single'"))
    }

    // MARK: numbers

    func testNumbers() {
        XCTAssertEqual(parse("0"), .int(0))
        XCTAssertEqual(parse("-0"), .int(0))
        XCTAssertEqual(parse("-17"), .int(-17))
        XCTAssertEqual(parse("1700000000000"), .int(1_700_000_000_000))
        XCTAssertEqual(parse("9223372036854775807"), .int(Int64.max))
        XCTAssertEqual(parse("2.5"), .double(2.5))
        XCTAssertEqual(parse("-0.001"), .double(-0.001))
        XCTAssertEqual(parse("1e3"), .int(1000), "whole doubles below 2^53 normalise to int")
        XCTAssertEqual(parse("1E-2"), .double(0.01))
        XCTAssertEqual(parse("1.5e+1"), .int(15))
        XCTAssertEqual(parse("1e21"), .double(1e21))
        XCTAssertEqual(parse("12345678901234567890"), .double(12345678901234567890))
    }

    func testRejectsMalformedNumbers() {
        XCTAssertNil(parse("01"), "leading zeros")
        XCTAssertNil(parse("1."))
        XCTAssertNil(parse(".5"))
        XCTAssertNil(parse("+1"))
        XCTAssertNil(parse("1e"))
        XCTAssertNil(parse("1e+"))
        XCTAssertNil(parse("-"))
        XCTAssertNil(parse("0x10"))
        XCTAssertNil(parse("NaN"))
        XCTAssertNil(parse("Infinity"))
        XCTAssertNil(parse("1e999"), "non-finite")
    }

    // MARK: rejection

    func testRejectsBareWordsAndGarbage() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
        XCTAssertNil(parse("garbage"))
        XCTAssertNil(parse("tru"))
        XCTAssertNil(parse("nul"))
        XCTAssertNil(parse("True"))
        XCTAssertNil(parse("undefined"))
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse("{\"a\":1} trailing"))
        XCTAssertNil(parse("{\"a\":1}{}"))
    }

    func testRejectsStructuralErrors() {
        XCTAssertNil(parse("{\"a\":1,}"), "trailing comma")
        XCTAssertNil(parse("[1,]"))
        XCTAssertNil(parse("[,1]"))
        XCTAssertNil(parse("{a:1}"), "unquoted key")
        XCTAssertNil(parse("{\"a\"}"))
        XCTAssertNil(parse("{\"a\":}"))
        XCTAssertNil(parse("{\"a\" 1}"))
        XCTAssertNil(parse("[1 2]"))
        XCTAssertNil(parse("{\"a\":1"))
        XCTAssertNil(parse("[1"))
        XCTAssertNil(parse("// comment\n{}"))
        XCTAssertNil(parse("{\"a\":1}\u{0}"))
    }

    // MARK: JSONSerialization-backed parse

    func testFoundationParseHandlesObjectsAndArrays() throws {
        let value = try XCTUnwrap(JSONParser.parse("{\"s\":\"x\",\"i\":1,\"d\":2.5,\"t\":true,\"n\":null,\"a\":[1,2]}"))
        XCTAssertEqual(value["s"], .string("x"))
        XCTAssertEqual(value["i"], .int(1))
        XCTAssertEqual(value["d"], .double(2.5))
        XCTAssertEqual(value["t"], .bool(true))
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["a"], .array([.int(1), .int(2)]))
        XCTAssertEqual(Set(value.objectKeys), ["s", "i", "d", "t", "n", "a"])
        XCTAssertEqual(JSONParser.parse("[true,false]"), .array([.bool(true), .bool(false)]))
    }

    func testFoundationParseRejectsGarbageAndBareScalars() {
        XCTAssertNil(JSONParser.parse("garbage"))
        XCTAssertNil(JSONParser.parse("{not json"))
        XCTAssertNil(JSONParser.parse("\"x\""), "scalar at the top level")
        XCTAssertNil(JSONParser.parse("42"))
    }

    func testBothParsersAgreeOnRecords() throws {
        let record = "{\"v\":1,\"signals\":{\"track\":true,\"identify\":false,\"cookieSync\":true},"
            + "\"input\":{\"analytics\":true},\"source\":\"manual\",\"ts\":1699999999990,\"exp\":1731536000000}"
        let ordered = try XCTUnwrap(parse(record))
        let foundation = try XCTUnwrap(JSONParser.parse(record))
        XCTAssertEqual(sortedJSONKeys(ordered), sortedJSONKeys(foundation))
        XCTAssertEqual(JSONWriter.string(ordered), record)
    }
}
