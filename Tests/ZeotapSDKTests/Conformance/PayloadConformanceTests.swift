import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/payload.vectors.json — exact payloads from the real engine with pinned
/// uuid/clock/identity, compared after substituting `$LIBRARY_NAME`/`$LIBRARY_VERSION` and stripping
/// the iOS-only context blocks (which the web never sends) and the browser-only `ignoreContextKeys`.
final class PayloadConformanceTests: XCTestCase {
    func testPayloadVectors() throws {
        let cases = VectorLoader.cases("payload")
        XCTAssertFalse(cases.isEmpty, "no payload vectors loaded")
        for testCase in cases {
            try XCTContext.runActivity(named: "payload/\(testCase.id)") { _ in
                try run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func run(_ id: String, input: JSONValue, expected: JSONValue) throws {
        let fixture = try XCTUnwrap(input["fixture"], id)
        let namespace = try XCTUnwrap(input["namespace"]?.stringValue, id)
        var extra: [String: String] = [:]
        for (k, v) in fixture["storage"]?.objectPairs ?? [] { extra[k] = v.stringValue ?? "" }
        let storage = CoreHarness.seededStorage(anonymousId: try XCTUnwrap(fixture["anonymousId"]?.stringValue), namespace: namespace, extra: extra)
        let options = input["options"] ?? .object([])
        var config = Configuration(apiHost: "https://ingest.example")
        config.namespace = namespace
        if let meta = options["integration"] {
            config.integration = IntegrationMeta(name: meta["name"]?.stringValue ?? "", version: meta["version"]?.stringValue ?? "")
        }
        let h = CoreHarness(config: config, storage: storage, libraryName: "$LIBRARY_NAME", libraryVersion: "$LIBRARY_VERSION")

        for call in input["calls"]?.arrayValue ?? [] {
            let args = call["args"]?.arrayValue ?? []
            func str(_ i: Int) -> String? { i < args.count ? args[i].stringValue : nil }
            func map(_ i: Int) -> [String: Any]? { i < args.count ? asDictionary(args[i]) : nil }
            switch call["method"]?.stringValue {
            case "track": h.core.track(str(0) ?? "", properties: map(1), completion: nil)
            case "identify": h.core.identify(userId: str(0), traits: map(1), completion: nil)
            case "screen": h.core.screen(category: str(0), name: str(1), properties: map(2), completion: nil)
            case "group": h.core.group(str(0) ?? "", traits: map(1), completion: nil)
            case "alias": h.core.alias(str(0) ?? "", previousId: str(1), completion: nil)
            case "setConsent": h.core.setConsent(try XCTUnwrap(ConsentState.fromJSON(args[0]), "\(id): bad consent"))
            default: XCTFail("\(id): unsupported method")
            }
            h.settle()
        }
        h.flushAndSettle()

        // Stripped on BOTH sides, for symmetric reasons: this SDK sends context the
        // web SDK never does, and the web SDK sends context this one does not. What
        // is left is the cross-platform contract, which is what the suite is for.
        let actual = h.sentEvents().map(stripNonContract)
        let expectedPayloads = (expected["payloads"]?.arrayValue ?? []).map(stripNonContract)
        XCTAssertEqual(actual.count, expectedPayloads.count, "\(id): payload count")

        // messageIds are asserted as a SHAPE, not against the web SDK's literal
        // values, because the web SDK's uuid stream is shared with a feature this SDK
        // does not have. Its session is minted lazily at the first event, so on web
        // the stream runs messageId(1), sessionId(2), messageId(3) while here it runs
        // 1, 2 — the vectors' `fixture.uuidSequence` describes the web's interleaving,
        // and demanding it of a platform with no sessions would be asserting the
        // absence of a feature rather than the payload contract.
        //
        // What IS contractual — a fresh uuid v4 per event — is asserted here, and
        // every other field still compares literally below.
        let ids = actual.compactMap { $0["messageId"]?.stringValue }
        XCTAssertEqual(ids.count, actual.count, "\(id): every payload carries a messageId")
        XCTAssertEqual(Set(ids).count, ids.count, "\(id): messageIds are distinct")
        for messageId in ids {
            XCTAssertNotNil(
                messageId.range(of: Self.uuidV4, options: .regularExpression),
                "\(id): messageId \(messageId) is not a lowercase uuid v4"
            )
        }

        for (index, (a, e)) in zip(actual, expectedPayloads).enumerated() {
            // Properties/traits objects arrive from a Swift dictionary (sorted keys) — compare them
            // structurally regardless of order; everything else must match in order.
            let an = withOrdinalMessageId(a, index)
            let en = withOrdinalMessageId(e, index)
            XCTAssertTrue(equalIgnoringMapOrder(an, en, atKeysNamed: ["properties", "traits"]), "\(id)[\(index)]\n  actual:   \(JSONWriter.string(an))\n  expected: \(JSONWriter.string(en))")
            XCTAssertEqual(a.objectKeys, e.objectKeys, "\(id)[\(index)]: top-level key order")
        }
    }

    /// RFC-4122 v4, lowercase — what `IdGenerator` must produce for every event.
    private static let uuidV4 =
        "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    /// Positional messageId, so two platforms' uuid streams can be compared at all.
    private func withOrdinalMessageId(_ payload: JSONValue, _ index: Int) -> JSONValue {
        var out = payload
        out["messageId"] = .string("#\(index)")
        return out
    }

    private func stripNonContract(_ payload: JSONValue) -> JSONValue {
        let drop = platformContextKeys.union(webOnlyContextKeys)
        var out = payload
        if let ctx = payload["context"] {
            out["context"] = .object(ctx.objectPairs.filter { !drop.contains($0.0) })
        }
        return out
    }

    /// Equality where objects under the named keys compare as unordered maps.
    private func equalIgnoringMapOrder(_ a: JSONValue, _ b: JSONValue, atKeysNamed unordered: Set<String>) -> Bool {
        switch (a, b) {
        case let (.object(pa), .object(pb)):
            guard pa.count == pb.count else { return false }
            for (x, y) in zip(pa, pb) {
                guard x.0 == y.0 else { return false }
                if unordered.contains(x.0) {
                    guard sortedDeep(x.1) == sortedDeep(y.1) else { return false }
                } else if !equalIgnoringMapOrder(x.1, y.1, atKeysNamed: unordered) {
                    return false
                }
            }
            return true
        case let (.array(xa), .array(xb)):
            return xa.count == xb.count && zip(xa, xb).allSatisfy { equalIgnoringMapOrder($0, $1, atKeysNamed: unordered) }
        default:
            return a == b
        }
    }

    private func sortedDeep(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(pairs): return .object(pairs.sorted { $0.0 < $1.0 }.map { ($0.0, sortedDeep($0.1)) })
        case let .array(items): return .array(items.map(sortedDeep))
        default: return v
        }
    }

    /// JSON → the `[String: Any]` the public API takes (numbers as Double, like a JS caller).
    private func asDictionary(_ value: JSONValue) -> [String: Any]? {
        guard case let .object(pairs) = value else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in pairs { out[k] = asAny(v) }
        return out
    }

    private func asAny(_ value: JSONValue) -> Any {
        switch value {
        case let .string(s): return s
        case let .int(i): return Double(i)
        case let .double(d): return d
        case let .bool(b): return b
        case .null: return NSNull()
        case let .array(items): return items.map(asAny)
        case let .object(pairs):
            var out: [String: Any] = [:]
            for (k, v) in pairs { out[k] = asAny(v) }
            return out
        }
    }
}
