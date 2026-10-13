import Foundation

/// Wires the production collaborators for one `AnalyticsCore`. The caller starts it.
enum SdkFactory {
    static let libraryName = "@zeotap/ios-sdk"

    static func create(writeKey: String, configuration config: Configuration) -> AnalyticsCore {
        let logger: Logger = config.logger ?? OSLogger(debugEnabled: config.debug)
        let keys = Keys(namespace: config.namespace)
        let storage: KeyValueStore = config.storage ?? UserDefaultsStore()
        let identityStorage: KeyValueStore
        switch config.identityStorage {
        case .userDefaults: identityStorage = storage
        case let .keychain(accessGroup): identityStorage = KeychainStore(namespace: config.namespace, accessGroup: accessGroup, logger: logger)
        }
        let clock = SystemClock()
        let ids = SystemIdGenerator()
        let queue = DispatchQueue(label: "com.zeotap.sdk.core.\(config.namespace)", qos: .utility)
        let scheduler = DispatchScheduler(queue: queue)

        let identity = IdentityStore(keys: keys, storage: identityStorage, ids: ids)
        let userIdentities = UserIdentityManager(keys: keys, storage: storage, logger: logger)
        let consent = ConsentManager(clock: clock)
        let persistence = config.consent.persist ? ConsentPersistence(keys: keys, storage: storage, expiryDays: config.consent.expiryDays, clock: clock) : nil
        let tcfFactory = makeTcfFactory(config: config, consent: consent, scheduler: scheduler, clock: clock, logger: logger)
        let eventQueue = makeEventQueue(writeKey: writeKey, config: config, clock: clock, logger: logger)

        let networkMonitor = NWPathNetworkMonitor()
        // Always present, even when the host configured no provider: it is what backs
        // `Analytics.setAdvertisingId`, which a host may call long after `configure`.
        let manualAdvertisingId = ManualAdvertisingIdProvider()
        let contextCollector = DefaultContextCollector(
            collectAdvertisingId: config.collectAdvertisingId,
            advertisingIdProvider: HostFirstAdvertisingIdProvider(
                manual: manualAdvertisingId,
                delegate: config.advertisingIdProvider
            ),
            networkMonitor: networkMonitor
        )
        let payloadBuilder = PayloadBuilder(libraryName: libraryName, libraryVersion: SDKVersion.current, integration: config.integration, contextCollector: contextCollector)
        let transport = Transport(
            apiHost: config.apiHost,
            writeKey: writeKey,
            nativeAppId: config.nativeAppId,
            http: URLSessionHTTPClient(),
            clock: clock,
            scheduler: scheduler,
            logger: logger,
            userAgent: "ZeotapSDK/\(SDKVersion.current)"
        )
        let lifecycleEvents: LifecycleEvents? = config.trackApplicationLifecycleEvents
            ? LifecycleEvents(keys: keys, storage: storage, currentVersion: appVersion(), currentBuild: appBuild())
            : nil
        #if canImport(UIKit) && !os(watchOS)
        let lifecycle: AppLifecycle = UIKitAppLifecycle()
        let backgroundTasks: BackgroundTaskRunner = UIKitBackgroundTaskRunner()
        #else
        let lifecycle: AppLifecycle = NoopAppLifecycle()
        let backgroundTasks: BackgroundTaskRunner = NoopBackgroundTaskRunner()
        #endif

        return AnalyticsCore(
            writeKey: writeKey,
            config: config,
            scheduler: scheduler,
            clock: clock,
            ids: ids,
            identity: identity,
            userIdentities: userIdentities,
            consent: consent,
            consentPersistence: persistence,
            tcfFactory: tcfFactory,
            queue: eventQueue,
            transport: transport,
            payloadBuilder: payloadBuilder,
            lifecycle: lifecycle,
            backgroundTasks: backgroundTasks,
            network: networkMonitor,
            lifecycleEvents: lifecycleEvents,
            manualAdvertisingId: manualAdvertisingId,
            logger: logger
        )
    }

    /// The TCF integration, but only when the host asked for automatic CMP detection.
    /// Extracted from `create` to keep that function readable — it is the one place
    /// the whole object graph is visible, and burying a closure in the middle of it
    /// helps nobody.
    private static func makeTcfFactory(
        config: Configuration,
        consent: ConsentManager,
        scheduler: Scheduler,
        clock: Clock,
        logger: Logger
    ) -> ((@escaping () -> Void) -> TcfAppsIntegration)? {
        guard config.consent.resolvedCmp == .auto else { return nil }
        return { onDetected in
            TcfAppsIntegration(defaults: UserDefaultsTcfDefaults(), consent: consent, options: config.consent,
                               scheduler: scheduler, clock: clock, logger: logger, onDetected: onDetected)
        }
    }

    /// The durable queue, falling back to memory when SQLite cannot be opened.
    ///
    /// A fallback rather than a crash: a device with a full or locked container is a
    /// real state, and an SDK that refuses to initialise there takes the host app
    /// down with it. The cost — events lost on process death — is logged as an error
    /// so it is visible rather than silent.
    private static func makeEventQueue(
        writeKey: String,
        config: Configuration,
        clock: Clock,
        logger: Logger
    ) -> EventQueue {
        do {
            return try SQLiteEventQueue(
                path: queuePath(namespace: config.namespace, writeKey: writeKey),
                maxSize: config.maxQueueSize,
                clock: clock
            )
        } catch {
            logger.error("[SDK] SQLite queue unavailable; falling back to an in-memory queue", error)
            return InMemoryEventQueue(maxSize: config.maxQueueSize, clock: clock)
        }
    }

    /// `Library/Application Support/com.zeotap.sdk/<ns>/<sha256(writeKey) prefix>/events.sqlite`
    /// (the write key is scoped in so two keys in one app never share a queue).
    static func queuePath(namespace: String, writeKey: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let scoped = String(Hasher.sha256Hex(writeKey).prefix(16))
        let dir = base.appendingPathComponent("com.zeotap.sdk", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(scoped, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.sqlite").path
    }

    static func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    static func appBuild() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }
}
