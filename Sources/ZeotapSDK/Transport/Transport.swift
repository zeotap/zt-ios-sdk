import Foundation

/// What one `Transport.send` ended in; the engine decides ack/release/drop from it.
enum SendOutcome: Equatable {
    /// 2xx — the batch is delivered; `result` carries ingest's per-event verdict.
    case success(BatchResult)
    /// Non-retryable 4xx (≠ 429): the batch is wrong, not the network — drop it.
    case rejected(status: Int, body: String)
    /// All attempts failed on 5xx / 429 / transport error. `lastStatus` is the last HTTP status
    /// seen and `lastErrorDescription` the last error seen — both may be present when the
    /// attempts mixed the two failure kinds. The engine releases the rows.
    case exhausted(attempts: Int, lastStatus: Int?, lastErrorDescription: String?)
}

/// Port of the web SDK's `transport.ts` `send()`: POST `{batch, sentAt}` to `{apiHost}/v1/batch`,
/// retry 5xx / 429 / connection errors with 500 → 1000 → 2000 ms backoff (4 attempts total),
/// fail fast on any other 4xx. The body is built ONCE per call so every retry carries identical
/// bytes (same messageIds: ingest is at-least-once with no dedupe).
///
/// Threading: `send` is called on the core queue; HTTP completions hop back onto it through
/// `scheduler.async`, and the backoff waits are `scheduler.schedule(after:)` timers, so the
/// completion always runs on the core queue and tests drive the retries with virtual time.
/// All stored state is immutable, which is what makes the type safe to reference from the
/// `@Sendable` HTTP completion.
final class Transport: @unchecked Sendable {
    static let maxRetries = 3
    static let baseDelayMs: Int64 = 500
    /// Payload-byte budget per reserved batch (ingest caps the request at 10 MB).
    static let reserveMaxBytes = 4 * 1024 * 1024

    private let url: URL?
    private let writeKey: String
    private let nativeAppId: String
    private let http: HTTPClient
    private let clock: Clock
    private let scheduler: Scheduler
    private let logger: Logger
    private let userAgent: String

    init(apiHost: String, writeKey: String, nativeAppId: String, http: HTTPClient, clock: Clock, scheduler: Scheduler, logger: Logger, userAgent: String) {
        let host = apiHost.hasSuffix("/") ? String(apiHost.dropLast()) : apiHost
        self.url = URL(string: host + "/v1/batch")
        self.writeKey = writeKey
        self.nativeAppId = nativeAppId
        self.http = http
        self.clock = clock
        self.scheduler = scheduler
        self.logger = logger
        self.userAgent = userAgent
    }

    /// `payloads` are final, already-serialised event JSON objects. An empty batch never touches
    /// the network and completes synchronously (the caller is already on the core queue).
    func send(_ payloads: [String], completion: @escaping (SendOutcome) -> Void) {
        guard !payloads.isEmpty else {
            completion(.success(BatchResult(status: 200, success: true, received: 0, sent: 0, errors: [])))
            return
        }
        guard let url else {
            // Configuration validates apiHost, so this is unreachable in practice; an unusable
            // URL is deterministic, so treat it like a rejected batch rather than retrying forever.
            completion(.rejected(status: 0, body: "[SDK] apiHost is not a valid URL"))
            return
        }
        let request = Attempt(url: url, headers: headers(), body: body(payloads), sent: payloads.count)
        attempt(0, request, lastStatus: nil, lastError: nil, completion: completion)
    }

    // MARK: - Retry loop

    private struct Attempt {
        let url: URL
        let headers: [String: String]
        let body: Data
        let sent: Int
    }

    private func attempt(_ index: Int, _ request: Attempt, lastStatus: Int?, lastError: String?, completion: @escaping (SendOutcome) -> Void) {
        let completion = QueueHop(completion)
        http.post(url: request.url, headers: request.headers, body: request.body) { [self] result in
            scheduler.async { [self] in
                handle(result, attempt: index, request, lastStatus: lastStatus, lastError: lastError, completion: completion.value)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func handle(
        _ result: Result<HTTPResponse, Error>,
        attempt index: Int,
        _ request: Attempt,
        lastStatus: Int?,
        lastError: String?,
        completion: @escaping (SendOutcome) -> Void
    ) {
        var lastStatus = lastStatus
        var lastError = lastError
        switch result {
        case let .success(response):
            if (200...299).contains(response.status) {
                logger.debug("[SDK] Sent \(request.sent) events")
                completion(.success(parseResult(status: response.status, body: response.body, sent: request.sent)))
                return
            }
            if (400...499).contains(response.status) && response.status != 429 {
                logger.debug("[SDK] Ingest API error \(response.status): \(response.body)")
                completion(.rejected(status: response.status, body: response.body))
                return
            }
            lastStatus = response.status
        case let .failure(error):
            lastError = Transport.describe(error)
        }

        guard index < Transport.maxRetries else {
            logger.error("[SDK] Failed to send after \(Transport.maxRetries) retries (last status \(lastStatus.map(String.init) ?? "none"))", nil)
            completion(.exhausted(attempts: Transport.maxRetries + 1, lastStatus: lastStatus, lastErrorDescription: lastError))
            return
        }
        let delay = Transport.baseDelayMs << index
        logger.debug("[SDK] Retry \(index + 1)/\(Transport.maxRetries) in \(delay)ms")
        _ = scheduler.schedule(after: delay) { [self] in
            attempt(index + 1, request, lastStatus: lastStatus, lastError: lastError, completion: completion)
        }
    }

    // MARK: - Request

    /// `{"batch":[p1,p2,…],"sentAt":"<transmission time>"}` — the payloads are already JSON, so the
    /// envelope is concatenated rather than re-serialised.
    private func body(_ payloads: [String]) -> Data {
        var out = "{\"batch\":["
        out.append(payloads.joined(separator: ","))
        out.append("],\"sentAt\":\"")
        out.append(Iso8601.format(epochMs: clock.nowMs()))
        out.append("\"}")
        return Data(out.utf8)
    }

    private func headers() -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "X-Write-Key": writeKey,
            "User-Agent": userAgent
        ]
        if !nativeAppId.isEmpty { headers["X-Native-App-ID"] = nativeAppId }
        return headers
    }

    // MARK: - Response

    /// Ingest answers 200 even on partial failure: `{success:false, received:n, errors:["event 1: …"]}`.
    /// A missing/malformed body (204, proxies) reads as full success — the status already said so.
    private func parseResult(status: Int, body: String, sent: Int) -> BatchResult {
        guard let object = Transport.parseObject(body) else {
            return BatchResult(status: status, success: true, received: sent, sent: sent, errors: [])
        }
        let success = Transport.bool(object["success"]) ?? true
        let received = Transport.int(object["received"]) ?? sent
        let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
        return BatchResult(status: status, success: success, received: received, sent: sent, errors: errors)
    }

    private static func parseObject(_ body: String) -> [String: Any]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return nil }
        return parsed as? [String: Any]
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        // Through `Any`: Swift 6 compilers know every `Error` is CustomStringConvertible and reject
        // the direct cast as always-succeeding, while the Swift 5.10 Linux test host does not, and
        // for an error that is not, `localizedDescription` below is the answer on both.
        if let described = (error as Any) as? CustomStringConvertible { return described.description }
        return error.localizedDescription
    }
}
