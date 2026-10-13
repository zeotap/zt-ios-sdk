import XCTest
@testable import ZeotapSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `URLSessionHTTPClient` against a scripted `URLProtocol` registered on an ephemeral session (no
/// sockets): request shape, body/status pass-through for every status class, and error mapping.
/// Mirrors the Android `UrlConnectionHttpClientTest` (which uses MockWebServer).
final class URLSessionHTTPClientTests: XCTestCase {
    private let headers = [
        "Content-Type": "application/json",
        "X-Write-Key": "wk_test",
        "User-Agent": "ZeotapSDK/test"
    ]
    private let body = "{\"batch\":[{\"messageId\":\"m1\"}],\"sentAt\":\"2026-01-15T10:20:30.123Z\"}"
    // A `!` on a literal URL is the one force unwrap SwiftLint 0.60+ does not flag —
    // it can see the literal is valid — so the `disable:this` that used to sit here is
    // now itself a violation. Left as a plain force unwrap rather than restructured:
    // this is a test fixture over a constant, and a `guard` would add noise to say
    // nothing.
    private let url = URL(string: "https://ingest.example/v1/batch")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func client(timeout: TimeInterval = 5) -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPClient(session: URLSession(configuration: configuration), timeout: timeout)
    }

    private func post(_ client: URLSessionHTTPClient, to url: URL? = nil, body: Data? = nil) -> Result<HTTPResponse, Error>? {
        let done = expectation(description: "post completes")
        let box = ResultBox()
        client.post(url: url ?? self.url, headers: headers, body: body ?? Data(self.body.utf8)) { result in
            box.set(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return box.get()
    }

    // MARK: - Scripted protocol

    func testPostBodyAndHeadersArriveAndThe2xxBodyIsReturned() throws {
        StubURLProtocol.script = .response(status: 200, body: "{\"success\":true,\"received\":1}")

        let result = try XCTUnwrap(post(client()))

        XCTAssertEqual(try result.get(), HTTPResponse(status: 200, body: "{\"success\":true,\"received\":1}"))
        let recorded = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url, url)
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Write-Key"), "wk_test")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "User-Agent"), "ZeotapSDK/test")
        XCTAssertEqual(recorded.body.map { String(decoding: $0, as: UTF8.self) }, body)
    }

    func test204WithNoBodyYieldsEmptyString() throws {
        StubURLProtocol.script = .response(status: 204, body: nil)

        let result = try XCTUnwrap(post(client()))

        XCTAssertEqual(try result.get(), HTTPResponse(status: 204, body: ""))
    }

    func testNon2xxBodyIsReturnedNotThrown() throws {
        StubURLProtocol.script = .response(status: 400, body: "{\"error\":\"invalid JSON body\"}")

        let result = try XCTUnwrap(post(client()))

        XCTAssertEqual(try result.get(), HTTPResponse(status: 400, body: "{\"error\":\"invalid JSON body\"}"))
    }

    func test401And500ReturnTheirStatusWithoutFailing() throws {
        StubURLProtocol.script = .response(status: 401, body: "{\"error\":\"invalid write key\"}")
        let unauthorised = try XCTUnwrap(post(client()))
        XCTAssertEqual(try unauthorised.get().status, 401)
        XCTAssertEqual(try unauthorised.get().body, "{\"error\":\"invalid write key\"}")

        StubURLProtocol.script = .response(status: 500, body: nil)
        let serverError = try XCTUnwrap(post(client()))
        XCTAssertEqual(try serverError.get(), HTTPResponse(status: 500, body: ""))
    }

    func test429IsPassedThroughForTheTransportToRetry() throws {
        StubURLProtocol.script = .response(status: 429, body: "slow down")

        let result = try XCTUnwrap(post(client()))

        XCTAssertEqual(try result.get(), HTTPResponse(status: 429, body: "slow down"))
    }

    func testUTF8BodyBytesArePreservedInBothDirections() throws {
        StubURLProtocol.script = .response(status: 200, body: "{\"echo\":\"ünïcödé 🎉\"}")
        let payload = "{\"event\":\"ünïcödé 🎉\"}"

        let result = try XCTUnwrap(post(client(), body: Data(payload.utf8)))

        XCTAssertEqual(try result.get().body, "{\"echo\":\"ünïcödé 🎉\"}")
        XCTAssertEqual(StubURLProtocol.requests.first?.body.map { String(decoding: $0, as: UTF8.self) }, payload)
    }

    func testInvalidUTF8ResponseBodyIsDecodedLossilyNotDropped() throws {
        StubURLProtocol.script = .responseData(status: 200, data: Data([0x7B, 0xFF, 0xFE, 0x7D]))

        let result = try XCTUnwrap(post(client()))

        let text = try result.get().body
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertTrue(text.hasSuffix("}"))
        XCTAssertTrue(text.contains("\u{FFFD}"))
    }

    func testTransportLevelErrorCompletesWithFailure() throws {
        StubURLProtocol.script = .error(URLError(.notConnectedToInternet))

        let result = try XCTUnwrap(post(client()))

        guard case let .failure(error) = result else { return XCTFail("expected .failure, got \(result)") }
        XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
    }

    func testRequestUsesTheConfiguredTimeoutAndIgnoresCaches() throws {
        StubURLProtocol.script = .response(status: 200, body: "{}")

        _ = post(client(timeout: 7))

        let recorded = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(recorded.request.timeoutInterval, 7)
        XCTAssertEqual(recorded.request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testEachPostIsAnIndependentRequest() throws {
        StubURLProtocol.script = .response(status: 200, body: "{}")
        let http = client()

        _ = post(http)
        _ = post(http)
        _ = post(http)

        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(Set(StubURLProtocol.requests.map { $0.body.map { String(decoding: $0, as: UTF8.self) } ?? "" }), [body])
    }

    // MARK: - Real socket (Linux-safe): a refused connection is a `.failure`

    func testConnectionRefusedYieldsFailure() throws {
        let port = try XCTUnwrap(FreePort.reserveAndRelease())
        let dead = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/batch"))
        let http = URLSessionHTTPClient(session: URLSession(configuration: .ephemeral), timeout: 5)

        let result = try XCTUnwrap(post(http, to: dead))

        guard case .failure = result else { return XCTFail("expected .failure for a refused connection, got \(result)") }
    }
}

// MARK: - Helpers

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<HTTPResponse, Error>?

    func set(_ result: Result<HTTPResponse, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<HTTPResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Binds an ephemeral TCP port on loopback, then closes it — nothing listens there afterwards, so a
/// connect() is refused deterministically (unlike a hard-coded "probably unused" port).
private enum FreePort {
    static func reserveAndRelease() -> Int? {
        #if canImport(Glibc) || canImport(Musl)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { return nil }
        var actual = sockaddr_in()
        var actualLength = length
        let read = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
        }
        guard read == 0 else { return nil }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}

/// Scripted `URLProtocol`: every request records itself (URLRequest + body bytes) and is answered
/// from `script`. State is static because URLSession instantiates the protocol itself.
final class StubURLProtocol: URLProtocol {
    enum Script {
        case response(status: Int, body: String?)
        case responseData(status: Int, data: Data)
        case error(Error)
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _script: Script = .response(status: 200, body: "{}")
    nonisolated(unsafe) private static var _requests: [Recorded] = []

    static var script: Script {
        get { lock.lock(); defer { lock.unlock() }; return _script }
        set { lock.lock(); _script = newValue; lock.unlock() }
    }

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock()
        _script = .response(status: 200, body: "{}")
        _requests = []
        lock.unlock()
    }

    private static func record(_ recorded: Recorded) {
        lock.lock()
        _requests.append(recorded)
        lock.unlock()
    }

    // `static` cannot override: these are overrides of URLProtocol's `class func`
    // declarations, and Swift allows `class func` to be overridden only by
    // `class func`. The rule's advice is inapplicable here rather than ignored.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        // URLSession moves `httpBody` into `httpBodyStream` before the protocol sees it on some
        // Foundations; read whichever is present.
        let body = request.httpBody ?? request.httpBodyStream.map(StubURLProtocol.drain)
        StubURLProtocol.record(Recorded(request: request, body: body))

        guard let client, let url = request.url else { return }
        switch StubURLProtocol.script {
        case let .error(error):
            client.urlProtocol(self, didFailWithError: error)
        case let .response(status, body):
            respond(client, url: url, status: status, data: body.map { Data($0.utf8) })
        case let .responseData(status, data):
            respond(client, url: url, status: status, data: data)
        }
    }

    override func stopLoading() {}

    private func respond(_ client: URLProtocolClient, url: URL, status: Int, data: Data?) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data, !data.isEmpty { client.urlProtocol(self, didLoad: data) }
        client.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
