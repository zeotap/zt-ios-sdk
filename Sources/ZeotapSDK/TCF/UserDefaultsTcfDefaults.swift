import Foundation

/// `TcfDefaults` over `UserDefaults` (`.standard` by default), where IAB TCF-for-Apps CMP SDKs
/// publish the `IABTCF_*` keys. Change observation uses KVO on each key where the Objective-C
/// runtime exists, plus `UserDefaults.didChangeNotification` everywhere (the only channel on Linux).
/// Callbacks arrive on the writer's thread and may be duplicated — `TcfAppsIntegration` hops onto
/// the core queue and debounces.
final class UserDefaultsTcfDefaults: TcfDefaults {
    static let keyCmpSdkId = "IABTCF_CmpSdkID"
    static let keyGdprApplies = "IABTCF_gdprApplies"
    static let keyTcString = "IABTCF_TCString"
    static let keyPurposeConsents = "IABTCF_PurposeConsents"
    static let keyVendorConsents = "IABTCF_VendorConsents"
    static let observedKeys = [keyCmpSdkId, keyGdprApplies, keyTcString, keyPurposeConsents, keyVendorConsents]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> TcData {
        TcData(
            cmpSdkId: intValue(UserDefaultsTcfDefaults.keyCmpSdkId),
            gdprApplies: intValue(UserDefaultsTcfDefaults.keyGdprApplies).map { $0 != 0 },
            tcString: stringValue(UserDefaultsTcfDefaults.keyTcString),
            purposeConsents: stringValue(UserDefaultsTcfDefaults.keyPurposeConsents),
            vendorConsents: stringValue(UserDefaultsTcfDefaults.keyVendorConsents)
        )
    }

    func observe(_ onChange: @escaping () -> Void) -> ObservationToken {
        // onChange posts straight onto the core queue (see TcfAppsIntegration), so the thread the
        // notification arrives on never touches SDK state.
        let hop = QueueHop(onChange)
        let notification = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in hop.value() }
        #if canImport(ObjectiveC)
        let kvo = KeyObserver(defaults: defaults, keys: UserDefaultsTcfDefaults.observedKeys, onChange: onChange)
        return ObservationToken {
            NotificationCenter.default.removeObserver(notification)
            kvo.stop()
        }
        #else
        return ObservationToken { NotificationCenter.default.removeObserver(notification) }
        #endif
    }

    /// IAB mandates Int, but tolerate a CMP that wrote the number as a String.
    private func intValue(_ key: String) -> Int? {
        guard let object = defaults.object(forKey: key) else { return nil }
        if let s = object as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let n = object as? NSNumber { return n.intValue }
        if let i = object as? Int { return i }
        return nil
    }

    private func stringValue(_ key: String) -> String? {
        defaults.object(forKey: key) as? String
    }
}

#if canImport(ObjectiveC)
/// KVO helper — `UserDefaults` is KVO-compliant for its keys.
private final class KeyObserver: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: () -> Void
    private let lock = NSLock()
    private var active = true

    init(defaults: UserDefaults, keys: [String], onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    deinit { stop() }
}
#endif
