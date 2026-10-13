import Foundation
import ZeotapSDK
#if canImport(AppTrackingTransparency) && canImport(AdSupport)
import AdSupport
import AppTrackingTransparency
#endif

/// `AdvertisingIdProvider` over AppTrackingTransparency + AdSupport — the ONLY code in the SDK
/// that links those frameworks, which is why it ships as its own product: integrators that never
/// collect the advertising id do not pick up tracking frameworks (or their privacy-manifest
/// obligations). Never prompts: the host owns `ATTrackingManager.requestTrackingAuthorization`;
/// this reads the current status and the IDFA only when it is `.authorized`. Compiles to a
/// provider that always returns `nil` where the frameworks do not exist (Linux, older SDKs).
///
/// ```swift
/// var config = Configuration(apiHost: "https://events.zeotap.com")
/// config.collectAdvertisingId = true
/// config.advertisingIdProvider = ATTAdvertisingIdProvider()
/// ```
public final class ATTAdvertisingIdProvider: AdvertisingIdProvider, Sendable {
    public init() {}

    public func current() -> AdvertisingInfo? {
        #if canImport(AppTrackingTransparency) && canImport(AdSupport)
        let authorized = ATTrackingManager.trackingAuthorizationStatus == .authorized
        let id = authorized ? ASIdentifierManager.shared().advertisingIdentifier.uuidString : nil
        return AdvertisingInfo(id: id, trackingAuthorized: authorized)
        #else
        return nil
        #endif
    }
}
