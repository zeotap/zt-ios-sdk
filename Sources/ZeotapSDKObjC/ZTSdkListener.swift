#if canImport(ObjectiveC)
import Foundation
import ZeotapSDK

/// Objective-C view of `SdkListener`: batch results, delivery failures, dropped events and
/// internal errors, for ObjC hosts and the React Native bridge. Every method is optional, as
/// the Swift protocol's are defaulted. Register with `-[ZTAnalytics addListener:]`; callbacks
/// arrive on the configuration's `callbackQueue`.
///
/// The React Native bridge needed this to report anything at all on iOS: without an ObjC
/// listener API its event stream (`error` / `debug`) stayed silent there while Android's
/// reported rejected batches, exhausted deliveries and consent drops.
@objc(ZTSdkListener)
public protocol ZTSdkListener: AnyObject {
    /// A batch got a 2xx. `success` is the body's own verdict (ingest answers 200 on a
    /// partial failure), `errors` its per-event messages.
    @objc optional func onBatchResult(status: Int, success: Bool, received: Int, sent: Int, errors: [String])
    /// A batch was rejected with a non-retryable 4xx and dropped, or retries were exhausted.
    /// `status` is nil when no HTTP response was received.
    @objc optional func onDeliveryFailure(status: NSNumber?, attempts: Int, error: Error?)
    /// An event or identity update was dropped before delivery. `reason` is the
    /// `DropReason` raw value (`consentDenied`, `bufferFull`, `ingestRejected`, `enqueueFailed`).
    @objc optional func onEventDropped(type: String, reason: String, message: String)
    /// An unexpected internal error (storage, serialisation).
    @objc optional func onError(_ error: Error)
}

/// Adapts one `ZTSdkListener` onto `SdkListener`. The core holds listeners WEAKLY, so
/// `ZTAnalytics` keeps the adapter alive; the adapter holds its target weakly in turn, so a
/// listener that owns the `ZTAnalytics` (the React Native bridge does) is not retained in a cycle.
final class ZTSdkListenerAdapter: SdkListener {
    weak var target: ZTSdkListener?

    init(_ target: ZTSdkListener) {
        self.target = target
    }

    func onBatchResult(_ result: BatchResult) {
        target?.onBatchResult?(
            status: result.status, success: result.success,
            received: result.received, sent: result.sent, errors: result.errors
        )
    }

    func onDeliveryFailure(status: Int?, attempts: Int, error: Error?) {
        target?.onDeliveryFailure?(status: status.map { NSNumber(value: $0) }, attempts: attempts, error: error)
    }

    func onEventDropped(type: String, reason: DropReason, message: String) {
        target?.onEventDropped?(type: type, reason: reason.rawValue, message: message)
    }

    func onError(_ error: Error) {
        target?.onError?(error)
    }
}
#endif
