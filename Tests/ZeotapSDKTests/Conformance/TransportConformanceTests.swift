import XCTest
@testable import ZeotapSDK

/// `sdk/conformance/vectors/transport.vectors.json` against `Transport`.
///
/// Outcome mapping: web `succeeded` ⇔ `.success`, `threw` ⇔ `.rejected` (the web's
/// `Ingest API error <status>: <body>` message is reconstructed from status + body), `exhausted` ⇔
/// `.exhausted`. Header comparison ignores `User-Agent`: the vectors describe the browser's
/// fetch(), where the UA is not settable; iOS adds it (additive, documented in `runners/README.md`).
/// `keepalive`/`credentials` are fetch()-only options. Backoff is driven in virtual time through
/// `RecordingScheduler`, which also records the requested delays.
final class TransportConformanceTests: XCTestCase {
    private let fixedNow: Int64 = 1_768_472_430_123 // 2026-01-15T10:20:30.123Z

    func testVectors() throws {
        let cases = VectorLoader.cases("transport")
        XCTAssertFalse(cases.isEmpty, "no transport vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "transport/\(testCase.id)") { _ in
                run(testCase)
            }
        }
    }

    func testVectorFamilyDescribesTheSameConstants() throws {
        let document = try XCTUnwrap(VectorLoader.document("transport"))
        XCTAssertEqual(document["family"], .string("transport"))
        // MAX_RETRIES=3 → 4 attempts, 500 ms base: the notes pin them and the implementation must agree.
        XCTAssertEqual(Transport.maxRetries, 3)
        XCTAssertEqual(Transport.baseDelayMs, 500)
    }

    private func run(_ testCase: VectorLoader.Case) {
        let id = testCase.id
        let input = testCase.input
        let expected = testCase.expected

        guard let apiHost = input["apiHost"]?.stringValue,
              let writeKey = input["writeKey"]?.stringValue,
              let nativeAppId = input["nativeAppId"]?.stringValue,
              let eventCount = input["eventCount"]?.intValue,
              let responses = input["responses"]?.arrayValue,
              let script = ScriptedResponses.fromVector(responses) else {
            return XCTFail("\(id): malformed input \(JSONWriter.string(input))")
        }

        let queue = DispatchQueue(label: "com.zeotap.sdk.test.transport-conformance")
        let clock = FakeClock(nowMs: fixedNow)
        let scheduler = RecordingScheduler(queue: queue, clock: clock)
        let http = CapturingHTTPClient()
        http.scripted = script
        http.defaultResponse = .success(HTTPResponse(status: 599, body: "UNSCRIPTED"))
        let transport = Transport(
            apiHost: apiHost,
            writeKey: writeKey,
            nativeAppId: nativeAppId,
            http: http,
            clock: clock,
            scheduler: scheduler,
            logger: RecordingLogger(),
            userAgent: "ZeotapSDK/test"
        )
        let payloads = (0..<Int(eventCount)).map { "{\"messageId\":\"test-\($0 + 1)\"}" }

        guard let outcome = sendAndDrive(transport, payloads: payloads, scheduler: scheduler) else {
            return XCTFail("\(id): send never completed (requests=\(http.requests.count), delays=\(scheduler.delays))")
        }

        // attempts / delays
        XCTAssertEqual(http.requests.count, Int(expected["attempts"]?.intValue ?? -1), "\(id) attempts")
        let expectedDelays = (expected["delaysMs"]?.arrayValue ?? []).compactMap(\.intValue)
        XCTAssertEqual(scheduler.delays, expectedDelays, "\(id) delaysMs")
        XCTAssertLessThanOrEqual(http.requests.count, Transport.maxRetries + 1, "\(id) attempt cap")

        // outcome
        let expectedOutcome = expected["outcome"]?.stringValue ?? "?"
        switch outcome {
        case .success:
            XCTAssertEqual(expectedOutcome, "succeeded", "\(id) outcome (got .success)")
        case let .exhausted(attempts, _, _):
            XCTAssertEqual(expectedOutcome, "exhausted", "\(id) outcome (got .exhausted)")
            XCTAssertEqual(attempts, http.requests.count, "\(id) exhausted attempts")
        case let .rejected(status, body):
            XCTAssertEqual(expectedOutcome, "threw", "\(id) outcome (got .rejected)")
            if let prefix = expected["errorMessagePrefix"]?.stringValue {
                let message = ZeotapError.ingestRejected(status: status, body: body).localizedDescription
                XCTAssertTrue(message.hasPrefix(prefix), "\(id) errorMessagePrefix: \"\(message)\" does not start with \"\(prefix)\"")
            }
        }

        // request
        if let request = expected["request"] {
            guard let first = http.requests.first else { return XCTFail("\(id): expected a request") }
            XCTAssertEqual(first.url.absoluteString, request["url"]?.stringValue, "\(id) url")
            let expectedHeaders = request["headers"]?.stringDictionary ?? [:]
            var actualHeaders = first.headers
            actualHeaders.removeValue(forKey: "User-Agent") // additive on mobile
            XCTAssertEqual(actualHeaders, expectedHeaders, "\(id) headers")
            XCTAssertNotNil(first.headers["User-Agent"], "\(id) mobile always sends a User-Agent")
        }

        // envelope
        if let envelope = expected["envelope"] {
            guard let first = http.requests.first, let body = JSONParser.parseOrdered(first.body) else {
                return XCTFail("\(id): request body is not JSON")
            }
            let expectedKeys = (envelope["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
            XCTAssertEqual(body.objectKeys, expectedKeys, "\(id) envelope keys")
            XCTAssertEqual(body["batch"]?.arrayValue?.count, Int(envelope["batchLength"]?.intValue ?? -1), "\(id) batchLength")
            XCTAssertEqual(body["sentAt"]?.stringValue, envelope["sentAt"]?.stringValue, "\(id) sentAt")
            let batchIds = body["batch"]?.arrayValue?.map { $0["messageId"]?.stringValue }
            XCTAssertEqual(batchIds, payloads.indices.map { "test-\($0 + 1)" }, "\(id) batch payloads pass through untouched")
        }

        // sameBodyOnRetry
        if expected["sameBodyOnRetry"]?.boolValue == true, http.requests.count > 1 {
            XCTAssertEqual(Set(http.requests.map(\.body)).count, 1, "\(id) sameBodyOnRetry")
            XCTAssertEqual(Set(http.requests.map(\.url)).count, 1, "\(id) same url on retry")
        }
    }
}
