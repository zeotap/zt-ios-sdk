import Foundation

/// Key-value store for identifiers and consent (`{ns}_anonymous_id`, `{ns}_user_id`,
/// `{ns}_user_identities`, `{ns}_consent`, `{ns}_consent_tcf`, `{ns}_app_version`,
/// `{ns}_app_build`). Key names and JSON record shapes are identical to the browser SDK's
/// localStorage layout, so a hybrid app can seed a WebView from native state.
///
/// Default: `UserDefaults(suiteName: "com.zeotap.sdk")`. Hosts inject their own (e.g. encrypted)
/// store via `Configuration.storage`. Called from the SDK's serial queue only.
public protocol KeyValueStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

/// Log sink. Messages keep the browser SDK's `[SDK] …` wording. PII is never logged.
public protocol Logger: AnyObject, Sendable {
    func debug(_ message: String)
    func warn(_ message: String)
    func error(_ message: String, _ error: Error?)
}

/// Supplies the advertising identifier when `Configuration.collectAdvertisingId` is on. The core
/// never links AdSupport/AppTrackingTransparency — `ZeotapSDKAdSupport.ATTAdvertisingIdProvider`
/// does, and `ManualAdvertisingIdProvider` lets a host (or the React Native bridge) push the value.
public protocol AdvertisingIdProvider: AnyObject, Sendable {
    /// `nil` when unavailable / not authorised. Read on the SDK queue, once per payload.
    func current() -> AdvertisingInfo?
}

public struct AdvertisingInfo: Equatable, Sendable {
    /// The IDFA, or `nil` when ATT is not `.authorized`.
    public let id: String?
    public let trackingAuthorized: Bool

    public init(id: String?, trackingAuthorized: Bool) {
        self.id = id
        self.trackingAuthorized = trackingAuthorized
    }
}

/// Host-provided advertising id (mirrors the legacy `setATTStatusAndAdvertisingId`).
public final class ManualAdvertisingIdProvider: AdvertisingIdProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var info: AdvertisingInfo?
    private var assigned: Bool

    public init(_ info: AdvertisingInfo? = nil) {
        self.info = info
        self.assigned = info != nil
    }

    public func set(_ info: AdvertisingInfo?) {
        lock.lock()
        self.info = info
        assigned = true
        lock.unlock()
    }

    /// True once the host has set anything at all — **including `nil`**, which is a
    /// withdrawal and not the same as never having supplied a value.
    var hasValue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assigned
    }

    public func current() -> AdvertisingInfo? {
        lock.lock()
        defer { lock.unlock() }
        return info
    }
}

/// Host-supplied id wins over whatever the SDK could look up itself.
///
/// An app that called `setAdvertisingId` knows something the platform lookup does not — a
/// mediation SDK's value, or a deliberate withdrawal — so overriding it would be the SDK
/// second-guessing the integrator. When a host value is present the delegate is not merely
/// overridden but **not consulted**: on Android that saves a blocking IPC, and here it keeps
/// `ATTAdvertisingIdProvider` from re-reading a status the host has already spoken for.
///
/// `hasValue` is what distinguishes "the host withdrew the id" (a `nil` id that must be
/// honoured) from "the host never supplied one" (fall through to the delegate). Mirrors
/// `HostFirstAdvertisingIdProvider` on Android.
final class HostFirstAdvertisingIdProvider: AdvertisingIdProvider, @unchecked Sendable {
    private let manual: ManualAdvertisingIdProvider
    private let delegate: AdvertisingIdProvider?

    init(manual: ManualAdvertisingIdProvider, delegate: AdvertisingIdProvider?) {
        self.manual = manual
        self.delegate = delegate
    }

    func current() -> AdvertisingInfo? {
        if manual.hasValue { return manual.current() }
        return delegate?.current()
    }
}
