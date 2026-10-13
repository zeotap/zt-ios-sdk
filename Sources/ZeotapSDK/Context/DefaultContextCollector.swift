import Foundation
#if canImport(UIKit) && os(iOS)
@preconcurrency import UIKit
#endif

/// Current connectivity, read on every `collect()` for the `network` block. Implemented by
/// `NWPathNetworkMonitor`; absent (test hosts) → both false.
protocol NetworkStateProvider: AnyObject {
    var isWifi: Bool { get }
    var isCellular: Bool { get }
}

/// Production `ContextCollector`. The static blocks (`app`, the fixed part of `device`, `os`,
/// `screen`, `locale`, `timezone`, `userAgent`) are computed ONCE at construction and stored in
/// immutable properties, which is what makes the collector safe to read from the SDK queue; the
/// UIKit reads (`UIDevice`, `UIScreen`) happen on the main thread — synchronously when the SDK is
/// configured off it. `network` and the advertising info are refreshed per `collect()`: ATT
/// authorisation can change at runtime and `AdvertisingIdProvider.current()` is documented as
/// read once per payload.
///
/// Privacy: no device name, no carrier, no IP. The advertising id is attached only when the host
/// opted in AND supplied a provider AND tracking is authorised AND the value is not the all-zero
/// placeholder; `adTrackingEnabled` is reported whenever a provider exists.
final class DefaultContextCollector: ContextCollector {
    /// What the platform returns when tracking is not authorised.
    static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    private let collectAdvertisingId: Bool
    private let advertisingIdProvider: AdvertisingIdProvider?
    private let network: NetworkStateProvider?

    private let app: JSONValue
    private let deviceStatic: [(String, JSONValue)]
    private let os: JSONValue
    private let screen: JSONValue?
    private let locale: JSONValue
    private let timezone: JSONValue
    private let userAgent: JSONValue

    init(collectAdvertisingId: Bool, advertisingIdProvider: AdvertisingIdProvider?, networkMonitor: NetworkStateProvider?) {
        self.collectAdvertisingId = collectAdvertisingId
        self.advertisingIdProvider = advertisingIdProvider
        self.network = networkMonitor

        let platform = Platform.read()
        app = DefaultContextCollector.appBlock()
        var device: [(String, JSONValue)] = []
        if let id = platform.deviceId { device.append(("id", .string(id))) }
        device.append(("manufacturer", .string(Platform.manufacturer)))
        device.append(("model", .string(platform.model)))
        device.append(("type", .string(Platform.deviceType)))
        deviceStatic = device
        os = .object([("name", .string(platform.osName)), ("version", .string(platform.osVersion))])
        screen = platform.screen.map { s in
            .object([("width", .int(Int64(s.width))), ("height", .int(Int64(s.height))), ("density", .double(s.density))])
        }
        locale = .string(DefaultContextCollector.bcp47Locale())
        timezone = .string(TimeZone.current.identifier)
        userAgent = .string("ZeotapSDK/\(SDKVersion.current) (\(platform.model); \(platform.osName) \(platform.osVersion))")
    }

    func collect() -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = [
            ("app", app),
            ("device", .object(deviceBlock())),
            ("os", os),
            ("network", .object([("wifi", .bool(network?.isWifi ?? false)), ("cellular", .bool(network?.isCellular ?? false))]))
        ]
        if let screen { out.append(("screen", screen)) }
        out.append(("locale", locale))
        out.append(("timezone", timezone))
        out.append(("userAgent", userAgent))
        return out
    }

    // MARK: - Blocks

    private func deviceBlock() -> [(String, JSONValue)] {
        var device = deviceStatic
        guard collectAdvertisingId, let provider = advertisingIdProvider, let info = provider.current() else { return device }
        if info.trackingAuthorized, let id = info.id, id != DefaultContextCollector.zeroUUID {
            device.append(("advertisingId", .string(id)))
        }
        device.append(("adTrackingEnabled", .bool(info.trackingAuthorized)))
        return device
    }

    private static func appBlock() -> JSONValue {
        let bundle = Bundle.main
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return .object([
            ("name", .string(name)),
            ("version", .string(version)),
            ("build", .string(build)),
            ("namespace", .string(bundle.bundleIdentifier ?? ""))
        ])
    }

    /// `en-US` style: the first preferred language (already BCP-47), else the current locale
    /// identifier with POSIX underscores/encodings normalised away.
    private static func bcp47Locale() -> String {
        if let preferred = Locale.preferredLanguages.first, !preferred.isEmpty { return preferred }
        var identifier = Locale.current.identifier
        if let dot = identifier.firstIndex(where: { $0 == "." || $0 == "@" }) { identifier = String(identifier[..<dot]) }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: - Platform reads

/// The device/OS facts, gathered once. UIKit is touched on the main thread only.
private struct Platform: Sendable {
    struct Screen: Sendable {
        let width: Int
        let height: Int
        let density: Double
    }

    let deviceId: String?
    let model: String
    let osName: String
    let osVersion: String
    let screen: Screen?

    static var manufacturer: String {
        #if canImport(Darwin)
        return "Apple"
        #else
        return "unknown"
        #endif
    }

    static var deviceType: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }

    static func read() -> Platform {
        let model = machineModel()
        #if canImport(UIKit) && os(iOS)
        let ui = onMain { UIKitFacts.read() }
        return Platform(deviceId: ui.deviceId, model: model, osName: ui.osName, osVersion: ui.osVersion, screen: ui.screen)
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #if os(macOS)
        let name = "macOS"
        #elseif os(Linux)
        let name = "Linux"
        #else
        let name = "unknown"
        #endif
        return Platform(deviceId: nil, model: model, osName: name, osVersion: version, screen: nil)
        #endif
    }

    /// `utsname.machine` — `iPhone15,2` on device, the host architecture on the simulator/macOS;
    /// the simulator exports the emulated model in `SIMULATOR_MODEL_IDENTIFIER`.
    private static func machineModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    #if canImport(UIKit) && os(iOS)
    private struct UIKitFacts: Sendable {
        let deviceId: String?
        let osName: String
        let osVersion: String
        let screen: Screen?

        @MainActor
        static func read() -> UIKitFacts {
            let device = UIDevice.current
            let main = UIScreen.main
            let scale = Double(main.scale)
            let bounds = main.bounds
            let screen = Screen(
                width: Int((Double(bounds.width) * scale).rounded()),
                height: Int((Double(bounds.height) * scale).rounded()),
                density: scale
            )
            return UIKitFacts(
                deviceId: device.identifierForVendor?.uuidString,
                osName: device.systemName,
                osVersion: device.systemVersion,
                screen: screen
            )
        }
    }

    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
    #endif
}
