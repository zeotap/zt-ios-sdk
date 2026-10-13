import Foundation
import XCTest
@testable import ZeotapSDK

/// Order-sensitive structural equality with both sides printed as JSON on failure.
func assertJSONEqual(_ actual: JSONValue, _ expected: JSONValue, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
    if actual == expected { return }
    XCTFail("\(context)\n  actual:   \(JSONWriter.string(actual))\n  expected: \(JSONWriter.string(expected))", file: file, line: line)
}

/// Optional variant: `nil` compares as JSON `null`.
func assertJSONEqual(_ actual: JSONValue?, _ expected: JSONValue?, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
    assertJSONEqual(actual ?? .null, expected ?? .null, context, file: file, line: line)
}

/// Structural equality where object key ORDER is ignored (arrays stay ordered).
func assertJSONEquivalent(_ actual: JSONValue?, _ expected: JSONValue?, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
    let a = sortedJSONKeys(actual ?? .null)
    let e = sortedJSONKeys(expected ?? .null)
    if a == e { return }
    XCTFail("\(context)\n  actual:   \(JSONWriter.string(a))\n  expected: \(JSONWriter.string(e))", file: file, line: line)
}

/// Recursively sorts object keys.
func sortedJSONKeys(_ value: JSONValue) -> JSONValue {
    switch value {
    case let .object(pairs): return .object(pairs.sorted { $0.0 < $1.0 }.map { ($0.0, sortedJSONKeys($0.1)) })
    case let .array(items): return .array(items.map(sortedJSONKeys))
    default: return value
    }
}

/// A `KeyValueStore` snapshot as a JSON object (keys sorted) for readable diffs.
func storageJSON(_ snapshot: [String: String]) -> JSONValue {
    .object(snapshot.keys.sorted().map { ($0, JSONValue.string(snapshot[$0] ?? "")) })
}

extension JSONValue {
    /// `[String: String]` from an object whose members are all strings (non-strings become "").
    var stringDictionary: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in objectPairs { out[k] = v.stringValue ?? "" }
        return out
    }
}
