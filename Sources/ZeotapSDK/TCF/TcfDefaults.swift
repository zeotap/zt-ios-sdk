import Foundation

/// The IAB TCF-for-Apps data a CMP SDK writes to `UserDefaults.standard` (`IABTCF_*`). Bit strings
/// are '0'/'1' characters indexed from 1 (position i ↔ id i+1); `nil` = key absent.
struct TcData: Equatable, Sendable {
    var cmpSdkId: Int?
    var gdprApplies: Bool?
    var tcString: String?
    var purposeConsents: String?
    var vendorConsents: String?

    /// ⇔ `typeof window.__tcfapi === "function"` on the web.
    var cmpPresent: Bool { cmpSdkId != nil || gdprApplies != nil || tcString != nil }

    static let empty = TcData()
}

/// Read + observe the `IABTCF_*` defaults. Injectable so tests drive the timing model.
protocol TcfDefaults: AnyObject {
    func read() -> TcData
    /// Register a change callback; the returned token unregisters it when cancelled.
    func observe(_ onChange: @escaping () -> Void) -> ObservationToken
}

/// Cancellable observation handle.
final class ObservationToken {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit { cancel() }
}
