import Foundation

/// Host `[String: Any]` → `JSONValue`, normalised to the browser SDK's `JSON.stringify` value
/// space. Swift dictionaries are unordered, so keys are emitted SORTED — deterministic, and
/// documented as non-contractual (the web preserves a JS object's insertion order).
///
/// Values: `String`, `Bool`, integer types (`Int64` literal), `Double`/`Float` (whole & < 2^53 →
/// integer; else JavaScript number formatting; NaN/±Inf → `null`), `NSNumber` (booleans detected
/// as booleans), `Date` (→ ISO-8601 UTC), `URL` (→ absolute string), `[Any]`, `[String: Any]`,
/// `JSONValue` passthrough, `NSNull`/`nil` → `null`. Anything else throws
/// `ZeotapError.invalidProperties(key:)` — stricter than the web (which would let
/// `JSON.stringify` guess) because a `JSONSerialization` crash in a host app is worse than a
/// dropped event with a clear error.
enum JSONMapper {
    static func fromDictionary(_ dictionary: [String: Any]) throws -> JSONValue {
        var pairs: [(String, JSONValue)] = []
        pairs.reserveCapacity(dictionary.count)
        for key in dictionary.keys.sorted() {
            pairs.append((key, try fromValue(dictionary[key] as Any, key: key)))
        }
        return .object(pairs)
    }

    static func fromValue(_ value: Any, key: String) throws -> JSONValue {
        switch value {
        case let v as JSONValue: return v
        case is NSNull: return .null
        case let s as String: return .string(s)
        case let n as NSNumber: return fromNumber(n)
        case let d as Date: return .string(Iso8601.format(epochMs: Int64((d.timeIntervalSince1970 * 1000).rounded(.down))))
        case let u as URL: return .string(u.absoluteString)
        case let dict as [String: Any]: return try fromDictionary(dict)
        case let array as [Any]: return .array(try array.map { try fromValue($0, key: key) })
        default:
            // Swift optionals boxed as Any: nil → null, some → unwrap.
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return .null }
                return try fromValue(child.value, key: key)
            }
            throw ZeotapError.invalidProperties(key: key)
        }
    }

    /// Booleans are `NSNumber`s too; tell them apart before treating the value as a number.
    private static func fromNumber(_ n: NSNumber) -> JSONValue {
        if isBoolean(n) { return .bool(n.boolValue) }
        let d = n.doubleValue
        if !d.isFinite { return .null }
        // Integer-typed values keep exactness; doubles below 2^53 that are whole are integers too.
        // `objCType` ('f' float, 'd' double, anything else an integer encoding) is the portable way to
        // tell them apart — `CFNumberGetType` does not exist on swift-corelibs-foundation (Linux).
        let type = n.objCType.pointee
        if type == 0x66 || type == 0x64 {
            if d == d.rounded() && Swift.abs(d) < 9_007_199_254_740_992 { return .int(Int64(d)) }
            return .double(d)
        }
        return .int(n.int64Value)
    }

    static func isBoolean(_ n: NSNumber) -> Bool {
        #if canImport(ObjectiveC)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return type(of: n) == type(of: NSNumber(value: true)) && (n.int64Value == 0 || n.int64Value == 1) && n.objCType.pointee == 0x63 // 'c'
        #endif
    }
}
