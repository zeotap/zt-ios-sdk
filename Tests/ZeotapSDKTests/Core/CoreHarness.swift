import Foundation
import XCTest
@testable import ZeotapSDK

/// 2026-01-15T10:20:30.123Z — the instant every conformance vector is pinned to.
let fixedNowMs: Int64 = 1_768_472_430_123
let fixedAnon = "11111111-1111-4111-8111-111111111111"

/// Deterministic platform context so payload assertions are exact.
final class FakeContextCollector: ContextCollector {
    func collect() -> [(String, JSONValue)] {
        [
            ("app", .object([("name", .string("Sample")), ("version", .string("1.0")), ("build", .string("1")), ("namespace", .string("com.example"))])),
            ("device", .object([("manufacturer", .string("Apple")), ("model", .string("iPhone15,2")), ("type", .string("ios"))])),
            ("os", .object([("name", .string("iOS")), ("version", .string("17.4"))])),
            ("network", .object([("wifi", .bool(true)), ("cellular", .bool(false))])),
            ("screen", .object([("width", .int(1170)), ("height", .int(2532)), ("density", .double(3))])),
            ("locale", .string("en-US")),
            ("timezone", .string("Europe/Berlin")),
            ("userAgent", .string("ZeotapSDK/test"))
        ]
    }
}

/// Platform context keys the web SDK never sends (stripped before payload comparison).
let platformContextKeys: Set<String> = ["app", "device", "os", "network", "screen", "locale", "timezone", "userAgent"]

/// The mirror image: context the WEB SDK sends and the mobile SDKs do not, so the
/// vectors carry it and this SDK cannot be expected to reproduce it.
///
/// `page` was always here in spirit — the browser's page block, which is why the
/// `page` conformance cases are tagged `platforms:["js"]`. `session` arrived later,
/// from the sessions workstream on `main`: the web SDK now stamps `context.session`
/// on every payload, the vectors are generated from the real web SDK, and the mobile
/// SDKs have no sessions yet. That is a DEFERRED FEATURE, not a permanent
/// divergence — when mobile sessions land, delete the entry and the vectors become
/// the contract again. Documented in `sdk/conformance/README.md`.
let webOnlyContextKeys: Set<String> = ["page", "session"]

/// Builds an `AnalyticsCore` over fakes on one serial queue with virtual time. Callbacks are routed
/// onto the same queue so `settle()` covers them. Never wait on the flush timer with real time —
/// use `advance(by:)`.
final class CoreHarness {
    let queue = DispatchQueue(label: "com.zeotap.sdk.test.core")
    let clock: FakeClock
    let scheduler: FakeScheduler
    let ids: SequenceIdGenerator
    let storage: InMemoryStore
    let http: CapturingHTTPClient
    let logger = RecordingLogger()
    let eventQueue: InMemoryEventQueue
    let consent: ConsentManager
    let manualAdvertisingId: ManualAdvertisingIdProvider
    let core: AnalyticsCore
    let config: Configuration

    init(
        config: Configuration,
        storage: InMemoryStore = CoreHarness.seededStorage(),
        clock: FakeClock? = nil,
        scheduler: FakeScheduler? = nil,
        ids: SequenceIdGenerator? = nil,
        http: CapturingHTTPClient? = nil,
        tcfDefaults: FakeTcfDefaults? = nil,
        libraryName: String = "@zeotap/ios-sdk",
        libraryVersion: String = "0.0.0-test",
        // Both default to the deterministic fakes. Pass them together to exercise the real
        // context collector — the manual provider has to be built by the caller because the
        // collector needs it before the harness exists.
        manualAdvertisingId: ManualAdvertisingIdProvider = ManualAdvertisingIdProvider(),
        contextCollector: ContextCollector = FakeContextCollector(),
        autoStart: Bool = true
    ) {
        var config = config
        config.callbackQueue = queue
        self.config = config
        self.storage = storage
        self.clock = clock ?? FakeClock(nowMs: fixedNowMs)
        self.scheduler = scheduler ?? FakeScheduler(queue: queue, clock: self.clock)
        self.ids = ids ?? SequenceIdGenerator()
        self.http = http ?? CapturingHTTPClient()
        self.manualAdvertisingId = manualAdvertisingId
        let keys = Keys(namespace: config.namespace)
        eventQueue = InMemoryEventQueue(maxSize: config.maxQueueSize, clock: self.clock)
        consent = ConsentManager(clock: self.clock)
        let identity = IdentityStore(keys: keys, storage: storage, ids: self.ids)
        let userIdentities = UserIdentityManager(keys: keys, storage: storage, logger: logger)
        let transport = Transport(
            apiHost: config.apiHost,
            writeKey: "wk_test",
            nativeAppId: config.nativeAppId,
            http: self.http,
            clock: self.clock,
            scheduler: self.scheduler,
            logger: logger,
            userAgent: "ZeotapSDK/test"
        )
        let consentRef = consent
        let schedulerRef = self.scheduler
        let clockRef = self.clock
        let loggerRef = logger
        let options = config.consent
        core = AnalyticsCore(
            writeKey: "wk_test",
            config: config,
            scheduler: self.scheduler,
            clock: self.clock,
            ids: self.ids,
            identity: identity,
            userIdentities: userIdentities,
            consent: consent,
            consentPersistence: config.consent.persist ? ConsentPersistence(keys: keys, storage: storage, expiryDays: config.consent.expiryDays, clock: self.clock) : nil,
            tcfFactory: tcfDefaults.map { defaults in
                { onDetected in
                    TcfAppsIntegration(defaults: defaults, consent: consentRef, options: options,
                                       scheduler: schedulerRef, clock: clockRef, logger: loggerRef,
                                       onDetected: onDetected)
                }
            },
            queue: eventQueue,
            transport: transport,
            payloadBuilder: PayloadBuilder(libraryName: libraryName, libraryVersion: libraryVersion, integration: config.integration, contextCollector: contextCollector),
            lifecycle: nil,
            backgroundTasks: nil,
            network: nil,
            lifecycleEvents: nil,
            manualAdvertisingId: manualAdvertisingId,
            logger: logger
        )
        if autoStart {
            core.start()
            settle()
        }
    }

    /// Run everything posted to the core queue, including work that those blocks post in turn
    /// (an HTTP completion hops back via `scheduler.async`; callbacks and listener notifications
    /// go through `callbackQueue`, which is the same queue here). No time advance.
    func settle() {
        for _ in 0..<6 { scheduler.runPending() }
    }

    /// Advance virtual time by `ms`, firing due timers, then settle.
    func advance(_ ms: Int64) {
        scheduler.advance(by: ms)
        settle()
    }

    func flushAndSettle() {
        core.flush(completion: nil)
        settle()
    }

    /// Every event payload that reached ingest, in order.
    func sentEvents() -> [JSONValue] {
        http.requests.flatMap { request -> [JSONValue] in
            guard let body = JSONParser.parseOrdered(request.body), let batch = body["batch"]?.arrayValue else { return [] }
            return batch
        }
    }

    static func seededStorage(anonymousId: String = fixedAnon, namespace: String = "zeotap", extra: [String: String] = [:]) -> InMemoryStore {
        let store = InMemoryStore()
        store.set("\(namespace)_anonymous_id", anonymousId)
        for (k, v) in extra { store.set(k, v) }
        store.resetCounters()
        return store
    }

    static func baseConfig(_ build: (inout Configuration) -> Void = { _ in }) -> Configuration {
        var config = Configuration(apiHost: "https://ingest.example")
        build(&config)
        return config
    }

    static func gated(_ build: (inout ConsentOptions) -> Void = { _ in }) -> Configuration {
        baseConfig { config in
            config.consent.require = true
            config.consent.cmp = .none
            build(&config.consent)
        }
    }
}

/// Records completions in order.
final class RecordingCallback: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [Error?] = []

    var callback: Callback {
        { [self] error in
            lock.lock()
            calls.append(error)
            lock.unlock()
        }
    }

    var messages: [String?] { calls.map { $0?.localizedDescription } }
}

/// Collects listener notifications.
final class RecordingListener: SdkListener {
    var batchResults: [BatchResult] = []
    var deliveryFailures: [(status: Int?, attempts: Int)] = []
    var drops: [(type: String, reason: DropReason, message: String)] = []
    var errors: [Error] = []

    func onBatchResult(_ result: BatchResult) { batchResults.append(result) }
    func onDeliveryFailure(status: Int?, attempts: Int, error: Error?) { deliveryFailures.append((status, attempts)) }
    func onEventDropped(type: String, reason: DropReason, message: String) { drops.append((type, reason, message)) }
    func onError(_ error: Error) { errors.append(error) }
}

extension JSONValue {
    var typeString: String? { self["type"]?.stringValue }
    var eventName: String? { self["event"]?.stringValue }
    var userIdString: String? { self["userId"]?.stringValue }
    var contextValue: JSONValue? { self["context"] }
}
