#if canImport(ObjectiveC)
import Foundation
import ZeotapSDK

/// Objective-C mirror of `Configuration`. Property names, units (milliseconds) and defaults match
/// the Swift struct one-to-one; the nested `ConsentOptions` are flattened with a `consent` prefix
/// and enum-typed fields take their web string values (`"granted"`/`"denied"`, `"auto"`/`"none"`).
/// `toConfiguration()` converts, throwing `ZeotapError.invalidConfiguration` for an unknown enum
/// string; range validation happens when the `Analytics` instance is created.
@objc(ZTConfiguration)
public final class ZTConfiguration: NSObject {
    @objc public var apiHost: String
    @objc public var namespace: String = "zeotap"
    @objc public var flushAt: Int = 10
    @objc public var flushInterval: Int = 5000
    @objc public var debug: Bool = false
    @objc public var nativeAppId: String = ""

    // ---- consent (ConsentOptions) ----
    @objc public var consentRequire: Bool = false
    /// `"granted"` (default) or `"denied"`.
    @objc public var consentDefault: String = "granted"
    @objc public var consentCmpTimeoutMs: Int = 10_000
    @objc public var consentMaxBufferedEvents: Int = 10
    /// `"auto"`, `"none"`, or `nil` for the web default (`auto` when `consentRequire`, else `none`).
    @objc public var consentCmp: String?
    @objc public var consentPurposesForTracking: [NSNumber] = []
    @objc public var consentPurposesForIdentifying: [NSNumber] = []
    @objc public var consentPurposesForCookieSync: [NSNumber] = []
    @objc public var consentCheckVendorConsent: Bool = false
    @objc public var consentPersist: Bool = true
    @objc public var consentExpiryDays: Int = 365

    // ---- integration ----
    @objc public var integrationName: String?
    @objc public var integrationVersion: String?

    // ---- mobile additions ----
    @objc public var maxQueueSize: Int = 500
    @objc public var maxEventAgeDays: Int = 7
    @objc public var trackApplicationLifecycleEvents: Bool = false
    @objc public var flushOnBackground: Bool = true
    @objc public var collectAdvertisingId: Bool = false
    /// Store the anonymous/user id in the Keychain (survives reinstalls) instead of UserDefaults.
    @objc public var useKeychainIdentityStorage: Bool = false
    @objc public var keychainAccessGroup: String?
    @objc public var callbackQueue: DispatchQueue = .main

    private let manualAdvertisingId = ManualAdvertisingIdProvider()

    @objc public init(apiHost: String) {
        self.apiHost = apiHost
        super.init()
    }

    /// Host-supplied advertising id available **before** the SDK exists (the legacy
    /// `setATTStatusAndAdvertisingId`), for a host that already has the IDFA at configure
    /// time. Afterwards prefer `ZTAnalytics.setAdvertisingId(_:trackingAuthorized:)`, which
    /// needs no reference to this object; calling this later still works, but only while
    /// this same instance is alive, which is a lifetime the caller must not have to reason
    /// about.
    @objc public func setAdvertisingId(_ id: String?, trackingAuthorized: Bool) {
        manualAdvertisingId.set(AdvertisingInfo(id: id, trackingAuthorized: trackingAuthorized))
    }

    public func toConfiguration() throws -> Configuration {
        var config = Configuration(apiHost: apiHost)
        config.namespace = namespace
        config.flushAt = flushAt
        config.flushInterval = flushInterval
        config.debug = debug
        config.nativeAppId = nativeAppId

        var consent = ConsentOptions()
        consent.require = consentRequire
        guard let defaultValue = ConsentDefault(rawValue: consentDefault) else {
            throw ZeotapError.invalidConfiguration("consentDefault must be \"granted\" or \"denied\"")
        }
        consent.default = defaultValue
        consent.cmpTimeoutMs = consentCmpTimeoutMs
        consent.maxBufferedEvents = consentMaxBufferedEvents
        if let cmp = consentCmp {
            guard let mode = CmpMode(rawValue: cmp) else {
                throw ZeotapError.invalidConfiguration("consentCmp must be \"auto\" or \"none\"")
            }
            consent.cmp = mode
        }
        consent.purposesForTracking = consentPurposesForTracking.map(\.intValue)
        consent.purposesForIdentifying = consentPurposesForIdentifying.map(\.intValue)
        consent.purposesForCookieSync = consentPurposesForCookieSync.map(\.intValue)
        consent.checkVendorConsent = consentCheckVendorConsent
        consent.persist = consentPersist
        consent.expiryDays = consentExpiryDays
        config.consent = consent

        if let name = integrationName, let version = integrationVersion {
            config.integration = IntegrationMeta(name: name, version: version)
        }
        config.maxQueueSize = maxQueueSize
        config.maxEventAgeDays = maxEventAgeDays
        config.trackApplicationLifecycleEvents = trackApplicationLifecycleEvents
        config.flushOnBackground = flushOnBackground
        config.collectAdvertisingId = collectAdvertisingId
        if collectAdvertisingId { config.advertisingIdProvider = manualAdvertisingId }
        config.identityStorage = useKeychainIdentityStorage ? .keychain(accessGroup: keychainAccessGroup) : .userDefaults
        config.callbackQueue = callbackQueue
        return config
    }
}
#endif
