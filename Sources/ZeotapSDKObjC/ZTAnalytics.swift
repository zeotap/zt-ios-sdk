/// Module marker so `ZeotapSDKObjC` is never an empty target where Objective-C does not exist
/// (the Linux test host). Everything else in this module is `#if canImport(ObjectiveC)`.
public enum ZeotapSDKObjC {}

#if canImport(ObjectiveC)
import Foundation
import ZeotapSDK

/// Objective-C facade over `Analytics` for ObjC hosts and the React Native bridge. Every method
/// maps 1:1 onto the Swift API: `NSDictionary` properties/traits, `(NSError * _Nullable)` completions
/// delivered on `callbackQueue`, consent split into one method per `ConsentInput` form, and the
/// consent snapshot as a dictionary. `configure` also installs the instance as `Zeotap.shared`.
@objc(ZTAnalytics)
public final class ZTAnalytics: NSObject {
    /// The underlying Swift instance, for hosts mixing both languages.
    public let analytics: Analytics

    private static let sharedLock = NSLock()
    private static var sharedInstance: ZTAnalytics?

    /// Wraps an existing Swift instance.
    public init(analytics: Analytics) {
        self.analytics = analytics
        super.init()
    }

    /// `[[ZTAnalytics alloc] initWithWriteKey:configuration:error:]`.
    @objc public convenience init(writeKey: String, configuration: ZTConfiguration) throws {
        let config = try configuration.toConfiguration()
        self.init(analytics: try Analytics(writeKey: writeKey, namespace: config.namespace, configuration: config))
    }

    /// `[ZTAnalytics configureWithWriteKey:configuration:error:]` — creates the singleton
    /// (`Zeotap.shared` on the Swift side) and returns it.
    @objc @discardableResult
    public static func configure(writeKey: String, configuration: ZTConfiguration) throws -> ZTAnalytics {
        let config = try configuration.toConfiguration()
        let analytics = try Zeotap.configure(writeKey: writeKey, namespace: config.namespace) { $0 = config }
        let wrapper = ZTAnalytics(analytics: analytics)
        sharedLock.lock()
        sharedInstance = wrapper
        sharedLock.unlock()
        return wrapper
    }

    /// The instance created by `configure`, or `nil` before it.
    @objc public static var shared: ZTAnalytics? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return sharedInstance
    }

    // MARK: - Events

    @objc public func identify(userId: String?, traits: [String: Any]?, completion: ((Error?) -> Void)?) {
        analytics.identify(userId: userId, traits: traits, completion: ZTAnalytics.callback(completion))
    }

    @objc public func track(_ event: String, properties: [String: Any]?, completion: ((Error?) -> Void)?) {
        analytics.track(event, properties: properties, completion: ZTAnalytics.callback(completion))
    }

    @objc public func screen(name: String?, category: String?, properties: [String: Any]?, completion: ((Error?) -> Void)?) {
        analytics.screen(name, category: category, properties: properties, completion: ZTAnalytics.callback(completion))
    }

    @objc public func group(_ groupId: String, traits: [String: Any]?, completion: ((Error?) -> Void)?) {
        analytics.group(groupId, traits: traits, completion: ZTAnalytics.callback(completion))
    }

    @objc public func alias(_ newId: String, previousId: String?, completion: ((Error?) -> Void)?) {
        analytics.alias(newId, previousId: previousId, completion: ZTAnalytics.callback(completion))
    }

    // MARK: - Consent

    @objc public func setConsentTCFString(_ tcfString: String) {
        analytics.setConsent(.tcf(tcfString: tcfString))
    }

    @objc public func setConsentUSPrivacy(_ usPrivacy: String) {
        analytics.setConsent(.usPrivacy(usPrivacy))
    }

    /// Pre-resolved categories; pass `nil` for a category the CMP did not decide.
    @objc public func setConsentAnalytics(_ analytics: NSNumber?, marketing: NSNumber?, advertising: NSNumber?, functional: NSNumber?) {
        self.analytics.setConsent(.parsed(ParsedConsent(
            analytics: analytics?.boolValue,
            marketing: marketing?.boolValue,
            advertising: advertising?.boolValue,
            functional: functional?.boolValue
        )))
    }

    /// `{resolved: Bool, signals: {track, identify, cookieSync}?, source: String?, gdprApplies: Bool?}`
    /// — absent keys for unresolved state, like the web's `getConsentState()`.
    @objc public func getConsentState() -> [String: Any] {
        let state = analytics.getConsentState()
        var out: [String: Any] = ["resolved": state.resolved]
        if let signals = state.signals {
            out["signals"] = ["track": signals.track, "identify": signals.identify, "cookieSync": signals.cookieSync]
        }
        if let source = state.source { out["source"] = source.rawValue }
        if let gdprApplies = state.gdprApplies { out["gdprApplies"] = gdprApplies }
        return out
    }

    // MARK: - Identities

    @objc public func setUserIdentities(_ identities: [String: String], hashed: Bool, completion: ((Error?) -> Void)?) {
        analytics.setUserIdentities(identities, hashed: hashed, completion: ZTAnalytics.callback(completion))
    }

    /// `nil` or empty removes every identity.
    @objc public func unsetUserIdentities(_ keys: [String]?) {
        analytics.unsetUserIdentities(keys)
    }

    @objc public var anonymousId: String { analytics.anonymousId }

    @objc public var userId: String? { analytics.userId }

    // MARK: - Advertising id

    /// See `Analytics.setAdvertisingId(_:trackingAuthorized:)`. Works at any time after
    /// configuration — unlike `ZTConfiguration.setAdvertisingId`, it needs no reference to
    /// the configuration object that built this instance.
    @objc public func setAdvertisingId(_ id: String?, trackingAuthorized: Bool) {
        analytics.setAdvertisingId(id, trackingAuthorized: trackingAuthorized)
    }

    // MARK: - Lifecycle

    // Strong references to the adapters: the core holds listeners weakly (see
    // ZTSdkListenerAdapter), so without these an adapter would be released at once.
    private let listenerLock = NSLock()
    private var listenerAdapters: [ObjectIdentifier: ZTSdkListenerAdapter] = [:]

    /// `-[ZTAnalytics addListener:]`. Adding the same listener twice registers it once.
    @objc public func addListener(_ listener: ZTSdkListener) {
        listenerLock.lock()
        let key = ObjectIdentifier(listener)
        guard listenerAdapters[key] == nil else {
            listenerLock.unlock()
            return
        }
        let adapter = ZTSdkListenerAdapter(listener)
        listenerAdapters[key] = adapter
        listenerLock.unlock()
        analytics.addListener(adapter)
    }

    /// `-[ZTAnalytics removeListener:]`.
    @objc public func removeListener(_ listener: ZTSdkListener) {
        listenerLock.lock()
        let adapter = listenerAdapters.removeValue(forKey: ObjectIdentifier(listener))
        listenerLock.unlock()
        if let adapter { analytics.removeListener(adapter) }
    }

    @objc public func reset() {
        analytics.reset()
    }

    @objc public func flush(completion: (() -> Void)?) {
        analytics.flush(completion: completion)
    }

    @objc public func shutdown() {
        analytics.shutdown()
        ZTAnalytics.sharedLock.lock()
        if ZTAnalytics.sharedInstance === self { ZTAnalytics.sharedInstance = nil }
        ZTAnalytics.sharedLock.unlock()
    }

    private static func callback(_ completion: ((Error?) -> Void)?) -> Callback? {
        guard let completion else { return nil }
        return { error in completion(error) }
    }
}
#endif
