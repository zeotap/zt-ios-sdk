import Foundation

/// Completion callback for the event and identity APIs — the browser SDK's
/// `Callback = (err?: Error) => void`. `nil` once the call was enqueued (or applied); a
/// `ZeotapError` when it was dropped. Delivered on `Configuration.callbackQueue`.
public typealias Callback = @Sendable (Error?) -> Void

/// Result of one `/v1/batch` delivery. Ingest answers 200 even on partial failure
/// (`{success:false, errors:[…]}`), so the SDK parses the body and reports it here.
public struct BatchResult: Equatable, Sendable {
    /// HTTP status of the final attempt.
    public let status: Int
    /// `success` from the response body (true when absent on a 2xx).
    public let success: Bool
    /// `received` from the response body.
    public let received: Int
    /// Number of events in the batch.
    public let sent: Int
    /// `errors[]` from the response body, e.g. `event 0: missing type`.
    public let errors: [String]

    public init(status: Int, success: Bool, received: Int, sent: Int, errors: [String]) {
        self.status = status
        self.success = success
        self.received = received
        self.sent = sent
        self.errors = errors
    }
}

/// Reason an event or identity update never reached the queue.
public enum DropReason: String, Sendable {
    case consentDenied
    case bufferFull
    case ingestRejected
    case enqueueFailed
}

/// Observability hook — a deliberate improvement over the browser SDK, which only logs in debug
/// mode. All methods have empty defaults; invoked on `Configuration.callbackQueue`.
public protocol SdkListener: AnyObject {
    /// A batch was accepted (2xx) — inspect `result.success` / `result.errors`.
    func onBatchResult(_ result: BatchResult)
    /// A batch was rejected with a non-retryable 4xx and dropped, or retries were exhausted.
    func onDeliveryFailure(status: Int?, attempts: Int, error: Error?)
    /// An event (or identity update) was dropped before delivery.
    func onEventDropped(type: String, reason: DropReason, message: String)
    /// An unexpected internal error (storage, serialisation).
    func onError(_ error: Error)
}

public extension SdkListener {
    func onBatchResult(_ result: BatchResult) {}
    func onDeliveryFailure(status: Int?, attempts: Int, error: Error?) {}
    func onEventDropped(type: String, reason: DropReason, message: String) {}
    func onError(_ error: Error) {}
}
