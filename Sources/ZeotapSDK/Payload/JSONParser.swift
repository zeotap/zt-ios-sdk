import Foundation

/// JSON text → `JSONValue`.
///
/// Two entry points:
/// - `parse` wraps `Foundation.JSONSerialization` (objects/arrays at the top level only; object key
///   order is NOT preserved — fine for reads that look keys up by name).
/// - `parseOrdered` is a small hand-written recursive-descent parser with `JSON.parse` grammar
///   (RFC 8259 — any value at the top level, `\uXXXX` escapes incl. surrogate pairs, no trailing
///   commas, no leading zeros, no comments) that PRESERVES object key order. The SDK uses it wherever
///   the web's insertion order is observable (persisted identities) and the conformance runners use it
///   to read vectors whose key order is contractual.
enum JSONParser {
    /// `JSONSerialization`-based parse. `nil` for invalid JSON or a scalar at the top level.
    static func parse(_ text: String) -> JSONValue? {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return convert(object)
    }

    /// Order-preserving parse with `JSON.parse` semantics. `nil` for invalid JSON.
    static func parseOrdered(_ text: String) -> JSONValue? {
        var scanner = OrderedScanner(Array(text.unicodeScalars))
        return scanner.parseDocument()
    }

    // MARK: JSONSerialization → JSONValue

    static func convert(_ any: Any) -> JSONValue? {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber: return fromNumber(n)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(Int64(i))
        case let i as Int64: return .int(i)
        case let u as UInt64: return u <= UInt64(Int64.max) ? .int(Int64(u)) : .double(Double(u))
        case let d as Double: return normalise(d)
        case let f as Float: return normalise(Double(f))
        case let s as String: return .string(s)
        case let dict as [String: Any]:
            var pairs: [(String, JSONValue)] = []
            pairs.reserveCapacity(dict.count)
            for (key, value) in dict {
                guard let converted = convert(value) else { return nil }
                pairs.append((key, converted))
            }
            return .object(pairs)
        case let array as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(array.count)
            for value in array {
                guard let converted = convert(value) else { return nil }
                items.append(converted)
            }
            return .array(items)
        default: return nil
        }
    }

    private static func fromNumber(_ n: NSNumber) -> JSONValue {
        if JSONMapper.isBoolean(n) { return .bool(n.boolValue) }
        let type = n.objCType.pointee
        // 'f' float, 'd' double — everything else is an integer encoding.
        if type == 0x66 || type == 0x64 { return normalise(n.doubleValue) }
        return .int(n.int64Value)
    }

    /// Whole doubles below 2^53 are integers (what `JSON.stringify` would emit).
    private static func normalise(_ d: Double) -> JSONValue {
        if d.isFinite && d == d.rounded() && Swift.abs(d) < 9_007_199_254_740_992 { return .int(Int64(d)) }
        return .double(d)
    }
}

/// Recursive-descent `JSON.parse` over Unicode scalars.
private struct OrderedScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func parseDocument() -> JSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == scalars.count ? value : nil
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private mutating func skipWhitespace() {
        while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 }
    }

    private mutating func parseValue() -> JSONValue? {
        guard let c = current else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map(JSONValue.string)
        case "t": return literal("true") ? .bool(true) : nil
        case "f": return literal("false") ? .bool(false) : nil
        case "n": return literal("null") ? .null : nil
        case "-", "0"..."9": return parseNumber()
        default: return nil
        }
    }

    private mutating func literal(_ word: String) -> Bool {
        let expected = Array(word.unicodeScalars)
        guard index + expected.count <= scalars.count else { return false }
        for (offset, scalar) in expected.enumerated() where scalars[index + offset] != scalar { return false }
        index += expected.count
        return true
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1 // {
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if current == "}" {
            index += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard current == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard current == ":" else { return nil }
            index += 1
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            // JSON.parse: a duplicate key keeps its first position with the last value.
            if let existing = pairs.firstIndex(where: { $0.0 == key }) { pairs[existing].1 = value } else { pairs.append((key, value)) }
            skipWhitespace()
            guard let c = current else { return nil }
            if c == "," {
                index += 1
                continue
            }
            if c == "}" {
                index += 1
                return .object(pairs)
            }
            return nil
        }
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if current == "]" {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            guard let c = current else { return nil }
            if c == "," {
                index += 1
                continue
            }
            if c == "]" {
                index += 1
                return .array(items)
            }
            return nil
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func parseString() -> String? {
        index += 1 // opening quote
        var out = String.UnicodeScalarView()
        while let c = current {
            index += 1
            switch c {
            case "\"":
                return String(out)
            case "\\":
                guard let e = current else { return nil }
                index += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard let unit = parseHex4() else { return nil }
                    if unit >= 0xD800 && unit <= 0xDBFF {
                        // High surrogate: pair with a following \uDC00–\uDFFF when present.
                        if current == "\\", index + 1 < scalars.count, scalars[index + 1] == "u" {
                            let saved = index
                            index += 2
                            if let low = parseHex4(), low >= 0xDC00 && low <= 0xDFFF {
                                let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                                out.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
                                continue
                            }
                            index = saved
                        }
                        out.append("\u{FFFD}") // lone surrogate — unrepresentable in a Swift String
                    } else if unit >= 0xDC00 && unit <= 0xDFFF {
                        out.append("\u{FFFD}")
                    } else {
                        out.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    }
                default: return nil
                }
            default:
                if c.value < 0x20 { return nil } // unescaped control character
                out.append(c)
            }
        }
        return nil // unterminated
    }

    private mutating func parseHex4() -> UInt32? {
        guard index + 4 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = scalars[index]
            index += 1
            guard let digit = OrderedScanner.hexDigit(c) else { return nil }
            value = value << 4 | digit
        }
        return value
    }

    private static func hexDigit(_ c: Unicode.Scalar) -> UInt32? {
        switch c.value {
        case 0x30...0x39: return c.value - 0x30
        case 0x41...0x46: return c.value - 0x41 + 10
        case 0x61...0x66: return c.value - 0x61 + 10
        default: return nil
        }
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        var isInteger = true
        if current == "-" { index += 1 }
        guard let first = current, OrderedScanner.isDigit(first) else { return nil }
        if first == "0" {
            index += 1
        } else {
            while let c = current, OrderedScanner.isDigit(c) { index += 1 }
        }
        if current == "." {
            isInteger = false
            index += 1
            guard let c = current, OrderedScanner.isDigit(c) else { return nil }
            while let c = current, OrderedScanner.isDigit(c) { index += 1 }
        }
        if current == "e" || current == "E" {
            isInteger = false
            index += 1
            if current == "+" || current == "-" { index += 1 }
            guard let c = current, OrderedScanner.isDigit(c) else { return nil }
            while let c = current, OrderedScanner.isDigit(c) { index += 1 }
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<index])
        let literal = String(text)
        if isInteger, let i = Int64(literal) { return .int(i) }
        guard let d = Double(literal), d.isFinite else { return nil }
        if d == d.rounded() && Swift.abs(d) < 9_007_199_254_740_992 { return .int(Int64(d)) }
        return .double(d)
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
}
