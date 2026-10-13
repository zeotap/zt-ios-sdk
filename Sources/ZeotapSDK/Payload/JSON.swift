import Foundation

/// An insertion-ordered JSON value. `Foundation.JSONSerialization` / `JSONEncoder` do not preserve
/// dictionary order on iOS 14–16, and the browser SDK's payload key order is part of what the
/// conformance vectors pin — so the SDK builds its own tree and writes it with `JSONWriter`.
public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    /// Ordered key/value pairs. Keys are unique; `set` replaces in place.
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)): return Double(a) == b
        case let (.double(a), .int(b)): return a == Double(b)
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 { return false }
            return true
        default: return false
        }
    }

    // MARK: Object helpers

    public subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case var .object(pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                if let value = newValue { pairs[index].1 = value } else { pairs.remove(at: index) }
            } else if let value = newValue {
                pairs.append((key, value))
            }
            self = .object(pairs)
        }
    }

    public var objectKeys: [String] {
        guard case let .object(pairs) = self else { return [] }
        return pairs.map { $0.0 }
    }

    public var objectPairs: [(String, JSONValue)] {
        guard case let .object(pairs) = self else { return [] }
        return pairs
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case let .int(i): return i
        case let .double(d) where d == d.rounded() && Swift.abs(d) < 9_007_199_254_740_992: return Int64(d)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Build an object from ordered pairs (duplicate keys keep the LAST value in the FIRST position).
    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var out: [(String, JSONValue)] = []
        for (k, v) in pairs {
            if let index = out.firstIndex(where: { $0.0 == k }) { out[index].1 = v } else { out.append((k, v)) }
        }
        return .object(out)
    }
}

/// Serialises `JSONValue` byte-compatibly with `JSON.stringify` (compact; escapes `"` `\` and
/// U+0000–U+001F only; non-ASCII emitted raw; whole doubles < 2^53 as integers; other doubles via
/// JavaScript `Number.prototype.toString` rules; NaN/±Inf as `null`).
public enum JSONWriter {
    public static func string(_ value: JSONValue) -> String {
        var out = ""
        out.reserveCapacity(256)
        write(value, into: &out)
        return out
    }

    public static func data(_ value: JSONValue) -> Data {
        Data(string(value).utf8)
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case let .string(s): writeString(s, into: &out)
        case let .int(i): out.append(String(i))
        case let .double(d): out.append(JSNumber.format(d))
        case let .bool(b): out.append(b ? "true" : "false")
        case .null: out.append("null")
        case let .array(items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                write(item, into: &out)
            }
            out.append("]")
        case let .object(pairs):
            out.append("{")
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out.append(",") }
                writeString(pair.0, into: &out)
                out.append(":")
                write(pair.1, into: &out)
            }
            out.append("}")
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}

/// JavaScript `Number.prototype.toString()` for finite doubles (ECMA-262 Number::toString):
/// shortest round-trip digits `d1…dk`, decimal exponent `n` (value = 0.d1…dk × 10^n);
/// `k ≤ n ≤ 21` → digits + zeros; `0 < n ≤ 21` → point after n digits; `−6 < n ≤ 0` → `0.000d`;
/// otherwise `d.ddde±x`. Whole doubles below 2^53 are emitted as integers by `JSONWriter` before
/// reaching this; `1e21` → `1e+21`, `12345678.9` → `12345678.9`, `1e-7` → `1e-7`.
public enum JSNumber {
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        if value == value.rounded() && Swift.abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        let negative = value < 0
        // Swift's description is the shortest round-trip repr: "123.456" | "1.23456785e+07" | "1e-05"
        let repr = Swift.abs(value).description
        let (digits, n) = decompose(repr)
        let k = digits.count
        let body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if n > 0 && n <= 21 {
            body = String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        } else if n > -6 && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let rest = k > 1 ? "." + String(digits.dropFirst()) : ""
            body = String(digits.prefix(1)) + rest + "e" + (e >= 0 ? "+" : "-") + String(Swift.abs(e))
        }
        return negative ? "-" + body : body
    }

    /// Splits a positive `description` into significant digits (no leading/trailing zeros) and the
    /// exponent `n` such that value = 0.digits × 10^n.
    static func decompose(_ repr: String) -> (String, Int) {
        let lower = repr.lowercased()
        let parts = lower.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = String(parts[0])
        let exp = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "+", with: "")) ?? 0 : 0
        let dotParts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(dotParts[0])
        let fracPart = dotParts.count > 1 ? String(dotParts[1]) : ""
        if intPart != "0" && !intPart.isEmpty {
            let digits = (intPart + fracPart).trimmingTrailingZeros()
            return (digits.isEmpty ? "0" : digits, intPart.count + exp)
        }
        let leadingZeros = fracPart.prefix { $0 == "0" }.count
        let digits = String(fracPart.dropFirst(leadingZeros)).trimmingTrailingZeros()
        return (digits.isEmpty ? "0" : digits, -leadingZeros + exp)
    }
}

private extension String {
    func trimmingTrailingZeros() -> String {
        var s = Substring(self)
        while s.last == "0" { s = s.dropLast() }
        return String(s)
    }
}
