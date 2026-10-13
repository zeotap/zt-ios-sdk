import Foundation

/// Where the anonymous / user id live. `.userDefaults` mirrors the web (uninstall = a fresh identity);
/// `.keychain` survives reinstalls — a deliberate identity-semantics change, opt in knowingly.
public enum IdentityStorage: Equatable, Sendable {
    case userDefaults
    case keychain(accessGroup: String?)
}

/// SDK configuration — the browser SDK's `LoadOptions` minus the browser-only keys
/// (storage/cookie*/firstPartyCookies/credentials/autoPage) plus the mobile-only keys. Names and
/// units are kept identical to the web so the React Native bridge passes one options object to
/// both platforms. `apiHost` is REQUIRED: the web default `""` means "same origin".
public struct Configuration: Sendable {
    /// Ingest base URL, e.g. `https://events.zeotap.com` or a first-party proxy.
    public var apiHost: String
    /// Storage-key namespace (`{namespace}_anonymous_id`, …). Default `zeotap`.
    public var namespace: String = "zeotap"
    /// Flush queued events after this many accumulate. Default 10.
    public var flushAt: Int = 10
    /// Flush queued events at this interval in ms. Default 5000.
    public var flushInterval: Int = 5000
    /// Debug logging. Default false.
    public var debug: Bool = false
    /// Snowflake Native App install id → `X-Native-App-ID`. Default empty.
    public var nativeAppId: String = ""
    public var consent: ConsentOptions = ConsentOptions()
    /// Wrapping integration (e.g. the React Native bridge) → `context.library.integration`.
    /// Both fields are required or the integration is dropped (web parity).
    public var integration: IntegrationMeta? {
        didSet {
            if let meta = integration, meta.name.isEmpty || meta.version.isEmpty { integration = nil }
        }
    }
    // ---- mobile additions ----
    /// Durable queue capacity; the OLDEST event is dropped beyond it. Default 500.
    public var maxQueueSize: Int = 500
    /// Queued events older than this are pruned at launch. Default 7.
    public var maxEventAgeDays: Int = 7
    /// Emit Application Installed / Updated / Opened / Backgrounded. Default false.
    public var trackApplicationLifecycleEvents: Bool = false
    /// Flush when the app moves to the background. Default true.
    public var flushOnBackground: Bool = true
    /// Attach the advertising id (needs an `advertisingIdProvider`, e.g. `ATTAdvertisingIdProvider`
    /// from `ZeotapSDKAdSupport`). The SDK never prompts for ATT — the host owns the prompt.
    public var collectAdvertisingId: Bool = false
    public var advertisingIdProvider: AdvertisingIdProvider?
    public var identityStorage: IdentityStorage = .userDefaults
    /// Queue callbacks are delivered on. Default main.
    public var callbackQueue: DispatchQueue = .main
    /// Override the log sink. Default: `os.Logger` (subsystem `com.zeotap.sdk`).
    public var logger: Logger?
    /// Override the identity/consent key-value store (e.g. an encrypted one). Default: UserDefaults.
    public var storage: KeyValueStore?

    public init(apiHost: String) {
        self.apiHost = apiHost
    }

    /// Validates and normalises (trailing slash stripped). Throws `ZeotapError.invalidApiHost` /
    /// `.invalidConfiguration`.
    func validated() throws -> Configuration {
        var copy = self
        let host = apiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ZeotapError.invalidApiHost(apiHost) }
        guard host.hasPrefix("http://") || host.hasPrefix("https://"), URL(string: host) != nil else {
            throw ZeotapError.invalidApiHost(apiHost)
        }
        copy.apiHost = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard Configuration.namespacePattern.firstMatch(in: namespace, range: NSRange(namespace.startIndex..., in: namespace)) != nil else {
            throw ZeotapError.invalidConfiguration("namespace must match ^[a-z0-9_-]{1,32}$")
        }
        guard flushAt >= 1 else { throw ZeotapError.invalidConfiguration("flushAt must be >= 1") }
        guard flushInterval > 0 else { throw ZeotapError.invalidConfiguration("flushInterval must be > 0") }
        guard maxQueueSize >= 1 else { throw ZeotapError.invalidConfiguration("maxQueueSize must be >= 1") }
        guard maxEventAgeDays >= 1 else { throw ZeotapError.invalidConfiguration("maxEventAgeDays must be >= 1") }
        try consent.validate()
        return copy
    }

    // swiftlint:disable:next force_try
    private static let namespacePattern = try! NSRegularExpression(pattern: "^[a-z0-9_-]{1,32}$")
}
