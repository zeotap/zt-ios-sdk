import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/gating.vectors.json — the browser SDK's consent-gate scenarios replayed
/// as scripts against the real engine: what reached the transport, per-callback outcomes, the
/// consent snapshot and the persisted keys must all match.
final class GatingConformanceTests: XCTestCase {
    func testGatingVectors() throws {
        let cases = VectorLoader.cases("gating")
        XCTAssertFalse(cases.isEmpty, "no gating vectors loaded")
        for testCase in cases {
            try XCTContext.runActivity(named: "gating/\(testCase.id)") { _ in
                try run(testCase.id, input: testCase.input, expected: testCase.expected)
            }
        }
    }

    private func config(_ options: JSONValue) -> Configuration {
        var config = Configuration(apiHost: "https://ingest.example")
        if let consent = options["consent"] {
            if let v = consent["require"]?.boolValue { config.consent.require = v }
            if let v = consent["default"]?.stringValue { config.consent.default = v == "denied" ? .denied : .granted }
            if let v = consent["cmpTimeoutMs"]?.intValue { config.consent.cmpTimeoutMs = Int(v) }
            if let v = consent["maxBufferedEvents"]?.intValue { config.consent.maxBufferedEvents = Int(v) }
            if let v = consent["cmp"]?.stringValue { config.consent.cmp = v == "auto" ? .auto : .none }
            if let v = consent["persist"]?.boolValue { config.consent.persist = v }
            if let v = consent["expiryDays"]?.intValue { config.consent.expiryDays = Int(v) }
        }
        return config
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func run(_ id: String, input: JSONValue, expected: JSONValue) throws {
        let namespace = try XCTUnwrap(input["namespace"]?.stringValue)
        let storage = CoreHarness.seededStorage(anonymousId: try XCTUnwrap(input["anonymousId"]?.stringValue), namespace: namespace)
        let baseOptions = input["options"] ?? .object([])
        let callbacks = CallbackBook()

        var h = CoreHarness(config: config(baseOptions), storage: storage)
        let http = h.http
        for step in input["steps"]?.arrayValue ?? [] {
            let cb = step["cb"]?.stringValue.map { callbacks.callback(for: $0) }
            switch step["op"]?.stringValue {
            case "track": h.core.track(step["event"]?.stringValue ?? "", properties: nil, completion: cb)
            case "identify": h.core.identify(userId: step["userId"]?.stringValue, traits: nil, completion: cb)
            case "screen": h.core.screen(category: nil, name: step["name"]?.stringValue, properties: nil, completion: cb)
            case "setUserIdentities":
                let pairs = (step["identities"]?.objectPairs ?? []).map { ($0.0, $0.1.stringValue) }
                h.core.setUserIdentities(pairs, hashed: step["hashed"]?.boolValue ?? false, completion: cb)
            case "unsetUserIdentities": h.core.unsetUserIdentities(step["keys"]?.arrayValue?.compactMap(\.stringValue))
            case "setConsent": h.core.setConsent(try XCTUnwrap(ConsentState.fromJSON(try XCTUnwrap(step["input"])), "\(id): bad consent"))
            case "advanceMs": h.advance(try XCTUnwrap(step["ms"]?.intValue))
            case "reset": h.core.reset()
            case "flush": h.core.flush(completion: nil)
            case "reload":
                h.flushAndSettle()
                h.core.shutdown()
                let opts = step["options"] ?? baseOptions
                // Same storage, clock, scheduler, ids and http so the whole script is one timeline.
                h = CoreHarness(config: config(opts), storage: storage, clock: h.clock, scheduler: nil, ids: h.ids, http: http)
            default: XCTFail("\(id): unsupported op")
            }
            h.settle()
            h.settle()
        }
        h.flushAndSettle()
        h.settle()

        // enqueued
        let enqueued: [JSONValue] = http.requests.flatMap { request -> [JSONValue] in
            guard let body = JSONParser.parseOrdered(request.body), let batch = body["batch"]?.arrayValue else { return [] }
            return batch.map { p in
                var pairs: [(String, JSONValue)] = [("type", p["type"] ?? .null)]
                if let v = p["event"] { pairs.append(("event", v)) }
                if let v = p["name"] { pairs.append(("name", v)) }
                if let v = p["userId"] { pairs.append(("userId", v)) }
                if let v = p["context"]?["consent"] { pairs.append(("consent", v)) }
                if let v = p["context"]?["identities"] { pairs.append(("identities", v)) }
                return .object(pairs)
            }
        }
        let expectedEnqueued = expected["enqueued"]?.arrayValue ?? []
        XCTAssertEqual(enqueued, expectedEnqueued, "\(id): enqueued\n  actual:   \(enqueued.map(JSONWriter.string))\n  expected: \(expectedEnqueued.map(JSONWriter.string))")

        // callbacks
        var expectedCallbacks: [String: String?] = [:]
        for (k, v) in expected["callbacks"]?.objectPairs ?? [] { expectedCallbacks[k] = v.isNull ? nil : v.stringValue }
        XCTAssertEqual(callbacks.snapshot(), expectedCallbacks, "\(id): callbacks")

        // consent state
        let state = h.core.getConsentState()
        var statePairs: [(String, JSONValue)] = [("resolved", .bool(state.resolved))]
        if let s = state.signals { statePairs.append(("signals", ConsentState.signalsToJSON(s))) }
        if let s = state.source { statePairs.append(("source", .string(s.rawValue))) }
        if let g = state.gdprApplies { statePairs.append(("gdprApplies", .bool(g))) }
        XCTAssertEqual(JSONValue.object(statePairs), expected["consentState"], "\(id): consentState")

        // storage
        let expectedStorage = try XCTUnwrap(expected["storage"])
        XCTAssertEqual(storage.get("\(namespace)_user_id").map(JSONValue.string) ?? .null, expectedStorage["userId"] ?? .null, "\(id): storage.userId")
        XCTAssertEqual(storage.get("\(namespace)_user_identities").flatMap(JSONParser.parseOrdered) ?? .null, expectedStorage["userIdentities"] ?? .null, "\(id): storage.userIdentities")
        XCTAssertEqual(storage.get("\(namespace)_consent").flatMap(JSONParser.parseOrdered) ?? .null, expectedStorage["consent"] ?? .null, "\(id): storage.consent")
    }
}

/// Records `callbacks[id] = nil | message` like the generator did.
private final class CallbackBook: @unchecked Sendable {
    private let lock = NSLock()
    private var book: [String: String?] = [:]

    func callback(for id: String) -> Callback {
        { [self] error in
            lock.lock()
            // `.some` — a bare nil through the subscript would remove the key instead of recording success
            book[id] = .some(error?.localizedDescription)
            lock.unlock()
        }
    }

    func snapshot() -> [String: String?] {
        lock.lock()
        defer { lock.unlock() }
        return book
    }
}
