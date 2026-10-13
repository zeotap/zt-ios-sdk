import XCTest
@testable import ZeotapSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mirrors `sdk/js/src/transport.test.ts` `send()` (and the Android `TransportTest`) plus the
/// response-body parsing the web SDK lacks. Virtual time: the backoff timers fire through
/// `RecordingScheduler`, never a real sleep.
final class TransportTests: XCTestCase {
    private final class Harness {
        let queue = DispatchQueue(label: "com.zeotap.sdk.test.transport")
        let clock = FakeClock(nowMs: fixedNowMs)
        let http = CapturingHTTPClient()
        let logger = RecordingLogger()
        let scheduler: RecordingScheduler
        let transport: Transport

        init(_ responses: [Result<HTTPResponse, Error>], apiHost: String = "https://api.example.com", nativeAppId: String = "") {
            scheduler = RecordingScheduler(queue: queue, clock: clock)
            http.scripted = responses
            // Anything past the script is a loud failure rather than a silent 200.
            http.defaultResponse = .success(HTTPResponse(status: 599, body: "UNSCRIPTED"))
            transport = Transport(
                apiHost: apiHost,
                writeKey: "wk_abc123",
                nativeAppId: nativeAppId,
                http: http,
                clock: clock,
                scheduler: scheduler,
                logger: logger,
                userAgent: "ZeotapSDK/test"
            )
        }

        func send(_ payloads: [String]) -> SendOutcome? {
            sendAndDrive(transport, payloads: payloads, scheduler: scheduler)
        }
    }

    private func events(_ count: Int = 1) -> [String] {
        (1...max(count, 1)).prefix(count).map { "{\"messageId\":\"test-\($0)\"}" }
    }

    private func status(_ code: Int, body: String = "{}") -> Result<HTTPResponse, Error> { ScriptedResponses.status(code, body: body) }
    private func network(_ message: String = "network") -> Result<HTTPResponse, Error> { ScriptedResponses.network(message) }

    // MARK: Request shape

    func testSendsPOSTToApiHostV1BatchWithTheExactHeaderSet() throws {
        let h = Harness([status(200)])
        _ = h.send(events())

        let request = try XCTUnwrap(h.http.requests.first)
        XCTAssertEqual(h.http.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/batch")
        XCTAssertEqual(request.headers, [
            "Content-Type": "application/json",
            "X-Write-Key": "wk_abc123",
            "User-Agent": "ZeotapSDK/test"
        ])
    }

    func testAddsXNativeAppIDOnlyWhenConfigured() throws {
        let h = Harness([status(200)], nativeAppId: "5d6c3a0e-0000-4000-8000-000000000001")
        _ = h.send(events())

        XCTAssertEqual(try XCTUnwrap(h.http.requests.first).headers, [
            "Content-Type": "application/json",
            "X-Write-Key": "wk_abc123",
            "X-Native-App-ID": "5d6c3a0e-0000-4000-8000-000000000001",
            "User-Agent": "ZeotapSDK/test"
        ])
    }

    func testBodyIsTheBatchEnvelopeWithSentAtFromTheClock() throws {
        let h = Harness([status(200)])
        _ = h.send(events(2))

        let body = try XCTUnwrap(h.http.requests.first).body
        XCTAssertEqual(body, "{\"batch\":[{\"messageId\":\"test-1\"},{\"messageId\":\"test-2\"}],\"sentAt\":\"2026-01-15T10:20:30.123Z\"}")
        let parsed = try XCTUnwrap(JSONParser.parseOrdered(body))
        XCTAssertEqual(parsed.objectKeys, ["batch", "sentAt"])
        XCTAssertEqual(parsed["batch"]?.arrayValue?.count, 2)
        XCTAssertEqual(parsed["sentAt"], .string(Iso8601.format(epochMs: fixedNowMs)))
    }

    func testSentAtIsTransmissionTime() throws {
        let h = Harness([status(200), status(200)])
        _ = h.send(events())
        h.clock.advance(byMs: 60_000)
        _ = h.send(events())

        XCTAssertEqual(h.http.requests.map { JSONParser.parseOrdered($0.body)?["sentAt"] }, [
            .string("2026-01-15T10:20:30.123Z"),
            .string("2026-01-15T10:21:30.123Z")
        ])
    }

    func testStripsTrailingSlashFromApiHostAndKeepsAPathPrefix() throws {
        let a = Harness([status(200)], apiHost: "https://api.example.com/")
        _ = a.send(events())
        XCTAssertEqual(a.http.requests.first?.url.absoluteString, "https://api.example.com/v1/batch")

        let b = Harness([status(200)], apiHost: "https://www.site.com/cdp")
        _ = b.send(events())
        XCTAssertEqual(b.http.requests.first?.url.absoluteString, "https://www.site.com/cdp/v1/batch")
    }

    // MARK: 2xx parsing

    func testResolvesSuccessOn200() throws {
        let h = Harness([status(200)])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .success(BatchResult(status: 200, success: true, received: 1, sent: 1, errors: [])))
        XCTAssertEqual(h.scheduler.delays, [])
    }

    func test200WithParsedBodyReportsIngestsPerEventVerdict() throws {
        let h = Harness([status(200, body: "{\"success\":false,\"received\":1,\"errors\":[\"event 1: x\"]}")])
        let outcome = try XCTUnwrap(h.send(events(2)))
        XCTAssertEqual(outcome, .success(BatchResult(status: 200, success: false, received: 1, sent: 2, errors: ["event 1: x"])))
    }

    func test200WithFullSuccessBody() throws {
        let h = Harness([status(200, body: "{\"success\":true,\"received\":3}")])
        let outcome = try XCTUnwrap(h.send(events(3)))
        XCTAssertEqual(outcome, .success(BatchResult(status: 200, success: true, received: 3, sent: 3, errors: [])))
    }

    func testMalformedOrEmpty2xxBodyStillCountsAsSuccess() throws {
        for body in ["", "   ", "not json", "[1,2]", "\"str\"", "{\"success\":\"yes\"}", "{\"errors\":[1,2]}"] {
            let h = Harness([status(204, body: body)])
            let outcome = try XCTUnwrap(h.send(events(2)), "body \(body)")
            XCTAssertEqual(outcome, .success(BatchResult(status: 204, success: true, received: 2, sent: 2, errors: [])), "body \(body)")
        }
    }

    func testNonStringErrorsAreIgnoredAndStringOnesKept() throws {
        let h = Harness([status(200, body: "{\"success\":false,\"received\":0,\"errors\":[\"a\",1,null,\"b\"]}")])
        let outcome = try XCTUnwrap(h.send(events(2)))
        XCTAssertEqual(outcome, .success(BatchResult(status: 200, success: false, received: 0, sent: 2, errors: ["a", "b"])))
    }

    func testEmptyPayloadListMakesNoRequestAndSucceeds() throws {
        let h = Harness([])
        let outcome = try XCTUnwrap(h.send([]))
        XCTAssertTrue(h.http.requests.isEmpty)
        XCTAssertEqual(h.scheduler.delays, [])
        XCTAssertEqual(outcome, .success(BatchResult(status: 200, success: true, received: 0, sent: 0, errors: [])))
    }

    // MARK: Retry classification

    func testRetriesUpTo3TimesWithExponentialBackoffOn500() throws {
        let h = Harness([status(500), status(500), status(500), status(200)])
        let outcome = try XCTUnwrap(h.send(events()))
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(h.http.requests.count, 4)
        XCTAssertEqual(h.scheduler.delays, [500, 1000, 2000])
        XCTAssertEqual(h.logger.debugs.filter { $0.hasPrefix("[SDK] Retry ") }, [
            "[SDK] Retry 1/3 in 500ms",
            "[SDK] Retry 2/3 in 1000ms",
            "[SDK] Retry 3/3 in 2000ms"
        ])
    }

    func testRetryWaitsForTheBackoffTimerBeforeTheNextAttempt() throws {
        let h = Harness([status(500), status(200)])
        let box = OutcomeBox()
        h.queue.sync { h.transport.send(self.events()) { box.set($0, onQueue: h.scheduler.isOnQueue) } }
        h.scheduler.runPending()

        XCTAssertEqual(h.http.requests.count, 1)
        XCTAssertNil(box.get())
        h.scheduler.advance(by: 499)
        XCTAssertEqual(h.http.requests.count, 1, "nothing before 500 ms")
        h.scheduler.advance(by: 1)
        h.scheduler.runPending()
        XCTAssertEqual(h.http.requests.count, 2)
        XCTAssertNotNil(box.get())
    }

    func testRetriesOn429() throws {
        let h = Harness([status(429), status(200)])
        let outcome = try XCTUnwrap(h.send(events()))
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(h.http.requests.count, 2)
        XCTAssertEqual(h.scheduler.delays, [500])
    }

    func testRetriesOn503And502() throws {
        let h = Harness([status(503), status(502), status(200)])
        _ = h.send(events())
        XCTAssertEqual(h.http.requests.count, 3)
        XCTAssertEqual(h.scheduler.delays, [500, 1000])
    }

    func test400IsRejectedImmediatelyWithTheBody() throws {
        let h = Harness([status(400, body: "{\"error\":\"invalid JSON body\"}")])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .rejected(status: 400, body: "{\"error\":\"invalid JSON body\"}"))
        XCTAssertEqual(h.http.requests.count, 1)
        XCTAssertEqual(h.scheduler.delays, [])
    }

    func test401IsRejectedImmediately() throws {
        let h = Harness([status(401)])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .rejected(status: 401, body: "{}"))
        XCTAssertEqual(h.http.requests.count, 1)
        XCTAssertEqual(h.scheduler.delays, [])
    }

    func testEvery4xxExcept429IsRejected() throws {
        for code in [400, 401, 403, 404, 405, 413, 422, 451, 499] {
            let h = Harness([status(code)])
            XCTAssertEqual(h.send(events()), .rejected(status: code, body: "{}"), "status \(code)")
            XCTAssertEqual(h.http.requests.count, 1, "status \(code)")
        }
    }

    func testRejectionReconstructsTheWebErrorMessage() throws {
        let h = Harness([status(400, body: "{}")])
        guard case let .rejected(status, body)? = h.send(events()) else { return XCTFail("expected rejected") }
        XCTAssertEqual(ZeotapError.ingestRejected(status: status, body: body).localizedDescription, "Ingest API error 400: {}")
        XCTAssertEqual(h.logger.debugs.last, "[SDK] Ingest API error 400: {}")
    }

    func testNonRetryableStatusAfterARetryStillRejectsImmediately() throws {
        let h = Harness([status(500), status(400)])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .rejected(status: 400, body: "{}"))
        XCTAssertEqual(h.http.requests.count, 2)
        XCTAssertEqual(h.scheduler.delays, [500])
    }

    func testConnectionErrorRetriesThenSucceeds() throws {
        let h = Harness([network("connect refused"), network("timeout"), status(200)])
        let outcome = try XCTUnwrap(h.send(events()))
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(h.http.requests.count, 3)
        XCTAssertEqual(h.scheduler.delays, [500, 1000])
    }

    func testURLErrorIsRetryable() throws {
        let h = Harness([.failure(URLError(.notConnectedToInternet)), status(200)])
        let outcome = try XCTUnwrap(h.send(events()))
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(h.http.requests.count, 2)
    }

    // MARK: Exhaustion

    func testExhaustionOn5xxReportsAttemptsAndLastStatus() throws {
        let h = Harness([status(500), status(502), status(503), status(500)])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .exhausted(attempts: 4, lastStatus: 500, lastErrorDescription: nil))
        XCTAssertEqual(h.http.requests.count, 4)
        XCTAssertEqual(h.scheduler.delays, [500, 1000, 2000])
        XCTAssertEqual(h.logger.errors, ["[SDK] Failed to send after 3 retries (last status 500)"])
    }

    func testExhaustionOnNetworkErrorsReportsTheLastError() throws {
        let h = Harness([network("1"), network("2"), network("3"), network("last")])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .exhausted(attempts: 4, lastStatus: nil, lastErrorDescription: "last"))
        XCTAssertEqual(h.scheduler.delays, [500, 1000, 2000])
        XCTAssertEqual(h.logger.errors, ["[SDK] Failed to send after 3 retries (last status none)"])
    }

    func testMixedFailuresKeepBothTheLastStatusAndTheLastError() throws {
        let h = Harness([status(503), network("net"), status(500), network("net")])
        let outcome = try XCTUnwrap(h.send(events()))
        XCTAssertEqual(outcome, .exhausted(attempts: 4, lastStatus: 500, lastErrorDescription: "net"))
    }

    func testExhaustedOn429x4() throws {
        let h = Harness([status(429), status(429), status(429), status(429)])
        XCTAssertEqual(h.send(events()), .exhausted(attempts: 4, lastStatus: 429, lastErrorDescription: nil))
        XCTAssertEqual(h.http.requests.count, 4)
    }

    func testNoFifthAttemptEvenIfTheServerWouldRecover() throws {
        let h = Harness([status(500), status(500), status(500), status(500), status(200)])
        _ = h.send(events())
        XCTAssertEqual(h.http.requests.count, Transport.maxRetries + 1)
        XCTAssertEqual(h.scheduler.inner.pendingTimerCount, 0, "no timer left armed after exhaustion")
    }

    // MARK: Body stability & threading

    func testSameBodyBytesAndHeadersOnEveryAttempt() throws {
        let h = Harness([status(500), network("x"), status(429), status(200)])
        // The clock moving between attempts must not change sentAt: the body is built once.
        _ = h.send(events(3))
        XCTAssertEqual(h.http.requests.count, 4)
        XCTAssertEqual(Set(h.http.requests.map(\.body)).count, 1)
        XCTAssertEqual(Set(h.http.requests.map { $0.headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }).count, 1)
        XCTAssertEqual(Set(h.http.requests.map(\.url)).count, 1)
        XCTAssertEqual(JSONParser.parseOrdered(h.http.requests[3].body)?["sentAt"], .string("2026-01-15T10:20:30.123Z"))
        XCTAssertEqual(h.clock.now, fixedNowMs + 500 + 1000 + 2000, "virtual time did advance through the backoff")
    }

    func testCompletionIsDeliveredExactlyOnceOnTheSchedulerQueue() throws {
        for script in [[status(200)], [status(500), status(200)], [status(400)], [status(500), status(500), status(500), status(500)]] {
            let h = Harness(script)
            let box = OutcomeBox()
            h.queue.sync { h.transport.send(self.events()) { box.set($0, onQueue: h.scheduler.isOnQueue) } }
            h.scheduler.runPending()
            while box.get() == nil, h.scheduler.fireNext() { h.scheduler.runPending() }
            XCTAssertNotNil(box.get())
            XCTAssertEqual(box.count, 1)
            XCTAssertTrue(box.wasDeliveredOnQueue, "completion must run on the core queue")
        }
    }

    func testEmptyBatchCompletesSynchronouslyOnTheCallersQueue() throws {
        let h = Harness([])
        var fired = false
        var onQueue = false
        h.queue.sync {
            h.transport.send([]) { _ in
                fired = true
                onQueue = h.scheduler.isOnQueue
            }
            XCTAssertTrue(fired, "an empty batch completes before send returns")
        }
        XCTAssertTrue(onQueue)
    }

    func testHTTPCompletionOffTheQueueIsHoppedBackOntoIt() throws {
        // A real URLSession completes on its own thread; the transport must hop onto the scheduler
        // queue before touching the completion.
        let h = Harness([])
        let offQueue = OffQueueHTTPClient(response: .success(HTTPResponse(status: 200, body: "{}")))
        let transport = Transport(
            apiHost: "https://api.example.com",
            writeKey: "wk",
            nativeAppId: "",
            http: offQueue,
            clock: h.clock,
            scheduler: h.scheduler,
            logger: h.logger,
            userAgent: "ZeotapSDK/test"
        )
        let box = OutcomeBox()
        let done = expectation(description: "completion")
        h.queue.sync {
            transport.send(self.events()) { outcome in
                box.set(outcome, onQueue: h.scheduler.isOnQueue)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(box.wasDeliveredOnQueue)
        XCTAssertEqual(box.get(), .success(BatchResult(status: 200, success: true, received: 1, sent: 1, errors: [])))
    }

    func testConcurrentSendsDoNotShareState() throws {
        let h = Harness([status(500), status(200), status(200)])
        let first = OutcomeBox()
        let second = OutcomeBox()
        h.queue.sync {
            h.transport.send(["{\"messageId\":\"a\"}"]) { first.set($0, onQueue: true) }
            h.transport.send(["{\"messageId\":\"b\"}"]) { second.set($0, onQueue: true) }
        }
        h.scheduler.runPending()
        while first.get() == nil || second.get() == nil, h.scheduler.fireNext() { h.scheduler.runPending() }

        XCTAssertEqual(h.http.requests.count, 3)
        XCTAssertEqual(h.http.requests.map { JSONParser.parseOrdered($0.body)?["batch"]?.arrayValue?.first?["messageId"]?.stringValue }, ["a", "b", "a"])
        XCTAssertEqual(first.get(), .success(BatchResult(status: 200, success: true, received: 1, sent: 1, errors: [])))
        XCTAssertEqual(second.get(), .success(BatchResult(status: 200, success: true, received: 1, sent: 1, errors: [])))
    }

    // MARK: Constants & logging

    func testConstantsMatchTheWebSDK() {
        XCTAssertEqual(Transport.maxRetries, 3)
        XCTAssertEqual(Transport.baseDelayMs, 500)
        XCTAssertEqual(Transport.reserveMaxBytes, 4 * 1024 * 1024)
    }

    func testSuccessIsLoggedAtDebugWithTheWebWording() throws {
        let h = Harness([status(200)])
        _ = h.send(events(2))
        XCTAssertEqual(h.logger.debugs, ["[SDK] Sent 2 events"])
        XCTAssertTrue(h.logger.errors.isEmpty)
    }

    func testLogsNeverContainThePayload() throws {
        let h = Harness([status(500), status(400, body: "{\"error\":\"bad\"}")])
        _ = h.send(["{\"messageId\":\"secret-id\",\"userId\":\"pii\"}"])
        let all = h.logger.debugs + h.logger.warns + h.logger.errors
        XCTAssertFalse(all.joined().contains("secret-id"))
        XCTAssertFalse(all.joined().contains("pii"))
    }
}

/// `HTTPClient` whose completion arrives on a background thread, like `URLSession`.
private final class OffQueueHTTPClient: HTTPClient, @unchecked Sendable {
    private let response: Result<HTTPResponse, Error>

    init(response: Result<HTTPResponse, Error>) {
        self.response = response
    }

    func post(url: URL, headers: [String: String], body: Data, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) {
        let answer = response
        DispatchQueue.global().async { completion(answer) }
    }
}
