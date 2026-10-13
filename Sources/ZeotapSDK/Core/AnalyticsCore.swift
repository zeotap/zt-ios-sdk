import Foundation

// swiftlint:disable type_body_length
/// The engine — a port of the browser SDK's `AnalyticsClient` (`client.ts`) onto ONE serial
/// `DispatchQueue`. Every public method posts to that queue; all state below is touched only on
/// it, except the lock-protected snapshots served to other threads.
///
/// Mobile divergences (all documented in sdk/conformance/README.md): the queue is durable and
/// reserved/acked around each send; exhausted retries RELEASE the batch and back off instead of
/// dropping; ingest's response body is parsed and surfaced through `SdkListener`; hashing is
/// synchronous, so the web's async identity barrier is unnecessary (ordering comes from the queue).
final class AnalyticsCore {
    private enum Signal: String {
        case track
        case identify
    }

    /// A call held in the pre-consent buffer until consent resolves (`BufferedEvent` in client.ts).
    private struct BufferedEvent {
        let draft: EventDraft?
        let signal: Signal
        let completion: Callback?
        let apply: (() -> Void)?
    }

    let writeKey: String
    let config: Configuration
    let scheduler: Scheduler
    var queue: DispatchQueue { scheduler.queue }

    private let clock: Clock
    private let ids: IdGenerator
    private let identity: IdentityStore
    private let userIdentities: UserIdentityManager
    private let consent: ConsentManager
    private let consentPersistence: ConsentPersistence?
    private var tcf: TcfAppsIntegration?
    private let eventQueue: EventQueue
    private let transport: Transport
    private let payloadBuilder: PayloadBuilder
    private let lifecycle: AppLifecycle?
    private let backgroundTasks: BackgroundTaskRunner?
    private let network: NetworkMonitor?
    private let lifecycleEvents: LifecycleEvents?
    private let manualAdvertisingId: ManualAdvertisingIdProvider
    private let logger: Logger
    private let gatingActive: Bool

    private var preConsentBuffer: [BufferedEvent] = []
    private var consentTimer: ScheduledTask?
    private var flushTimer: ScheduledTask?
    private var inFlight = false
    private var backoffIndex = 0
    private var nextFlushAllowedAt: Int64 = 0
    private var started = false
    private var isShutdown = false
    private var pendingFlushCompletions: [() -> Void] = []

    private let snapshotLock = NSLock()
    private var consentSnapshot = ConsentStateSnapshot.unresolved
    private var anonymousIdSnapshot: String
    private var userIdSnapshot: String?
    private var listeners: [ObjectIdentifier: WeakListener] = [:]

    private struct WeakListener {
        weak var value: SdkListener?
    }

    init(
        writeKey: String,
        config: Configuration,
        scheduler: Scheduler,
        clock: Clock,
        ids: IdGenerator,
        identity: IdentityStore,
        userIdentities: UserIdentityManager,
        consent: ConsentManager,
        consentPersistence: ConsentPersistence?,
        tcfFactory: ((@escaping () -> Void) -> TcfAppsIntegration)?,
        queue: EventQueue,
        transport: Transport,
        payloadBuilder: PayloadBuilder,
        lifecycle: AppLifecycle?,
        backgroundTasks: BackgroundTaskRunner?,
        network: NetworkMonitor?,
        lifecycleEvents: LifecycleEvents?,
        manualAdvertisingId: ManualAdvertisingIdProvider,
        logger: Logger
    ) {
        self.writeKey = writeKey
        self.config = config
        self.scheduler = scheduler
        self.clock = clock
        self.ids = ids
        self.identity = identity
        self.userIdentities = userIdentities
        self.consent = consent
        self.consentPersistence = consentPersistence
        self.eventQueue = queue
        self.transport = transport
        self.payloadBuilder = payloadBuilder
        self.lifecycle = lifecycle
        self.backgroundTasks = backgroundTasks
        self.network = network
        self.lifecycleEvents = lifecycleEvents
        self.manualAdvertisingId = manualAdvertisingId
        self.logger = logger
        self.gatingActive = config.consent.gatingActive
        self.anonymousIdSnapshot = identity.anonymousId()
        self.userIdSnapshot = identity.userId()
        self.tcf = tcfFactory.map { factory in factory { [weak self] in self?.cancelConsentTimer() } }
        consent.onResolve { [weak self] resolution in self?.onConsentResolved(resolution) }
    }

    // MARK: - Advertising id

    /// Host-supplied advertising id. Read per payload, so it takes effect for subsequent
    /// events (never mid-payload). `nil` is a **withdrawal**, distinct from never having
    /// supplied one — see `HostFirstAdvertisingIdProvider`.
    ///
    /// Gated by `collectAdvertisingId`, the host's single switch for whether an advertising
    /// id may be collected at all. Calling this with the flag off is a **loud** no-op: a
    /// privacy-relevant decision made once, in one place, must not be reversible by a line
    /// of code nobody reviewed as a privacy change. Same rule as Android.
    func setAdvertisingId(_ id: String?, trackingAuthorized: Bool) {
        guard config.collectAdvertisingId else {
            logger.warn("[SDK] setAdvertisingId ignored: configuration.collectAdvertisingId is false")
            return
        }
        manualAdvertisingId.set(AdvertisingInfo(id: id, trackingAuthorized: trackingAuthorized))
    }

    // MARK: - Lifecycle

    /// Wire timers/observers. Called once by the factory after construction.
    func start() {
        scheduler.async { [self] in
            guard !started else { return }
            started = true
            do { try eventQueue.releaseAll() } catch { reportError(error) }
            do {
                let cutoff = clock.nowMs() - Int64(config.maxEventAgeDays) * 86_400_000
                _ = try eventQueue.prune(olderThanMs: cutoff)
            } catch { reportError(error) }

            // Hydrate a persisted decision BEFORE arming timers/CMP detection — a stronger
            // source simply overrides it later.
            if let stored = consentPersistence?.load() {
                consent.offer(stored)
                logger.debug("[SDK] Consent hydrated from storage")
            }
            scheduleConsentDefault()
            if config.consent.resolvedCmp == .auto { tcf?.start() }

            flushTimer = scheduler.repeating(every: Int64(config.flushInterval)) { [weak self] in self?.doFlush(force: false) }
            network?.start { [weak self] in
                self?.scheduler.async {
                    self?.resetBackoff()
                    self?.doFlush(force: true)
                }
            }
            lifecycle?.start(
                onForeground: { [weak self] in
                    self?.scheduler.async {
                        guard let self else { return }
                        self.resetBackoff()
                        if let event = self.lifecycleEvents?.onForeground() { self.trackLifecycle(event) }
                        self.doFlush(force: true)
                    }
                },
                onBackground: { [weak self] in
                    self?.scheduler.async {
                        guard let self else { return }
                        if let event = self.lifecycleEvents?.onBackground() { self.trackLifecycle(event) }
                        if self.config.flushOnBackground { self.doFlush(force: true, inBackground: true) }
                    }
                }
            )
            lifecycleEvents?.onLaunch().forEach { trackLifecycle($0) }
            logger.debug("[SDK] Initialized apiHost=\(config.apiHost) flushAt=\(config.flushAt) flushInterval=\(config.flushInterval)")
        }
    }

    /// Stop everything. Timers are cancelled on the queue; observers and the store closed after.
    func shutdown() {
        queue.sync { [self] in
            isShutdown = true
            flushTimer?.cancel()
            consentTimer?.cancel()
            tcf?.stop()
        }
        lifecycle?.stop()
        network?.stop()
        eventQueue.close()
    }

    // MARK: - Public surface (posted to the serial queue)

    func identify(userId: String?, traits: [String: Any]?, completion: Callback?) {
        let traitsJSON = mapped(traits, completion: completion)
        guard traitsJSON.ok else { return }
        scheduler.async { [self] in
            let draft = build("identify")
            if let userId, !userId.isEmpty { draft.set("userId", .string(userId)) }
            if let traits = traitsJSON.value { draft.set("traits", traits) }
            let apply: (() -> Void)? = (userId?.isEmpty == false) ? { [self] in setUserId(userId ?? "") } : nil
            submit(draft, signal: .identify, completion: completion, apply: apply)
        }
    }

    func track(_ event: String, properties: [String: Any]?, completion: Callback?) {
        guard !event.isEmpty else { return }
        let props = mapped(properties, completion: completion)
        guard props.ok else { return }
        scheduler.async { [self] in
            let draft = build("track")
            draft.set("event", .string(event))
            if let properties = props.value { draft.set("properties", properties) }
            submit(draft, signal: .track, completion: completion, apply: nil)
        }
    }

    func screen(category: String?, name: String?, properties: [String: Any]?, completion: Callback?) {
        let props = mapped(properties, completion: completion)
        guard props.ok else { return }
        scheduler.async { [self] in
            let draft = build("screen")
            if let category, !category.isEmpty { draft.set("category", .string(category)) }
            if let name, !name.isEmpty { draft.set("name", .string(name)) }
            if let properties = props.value { draft.set("properties", properties) }
            submit(draft, signal: .track, completion: completion, apply: nil)
        }
    }

    func group(_ groupId: String, traits: [String: Any]?, completion: Callback?) {
        guard !groupId.isEmpty else { return }
        let traitsJSON = mapped(traits, completion: completion)
        guard traitsJSON.ok else { return }
        scheduler.async { [self] in
            let draft = build("group")
            draft.set("groupId", .string(groupId))
            if let traits = traitsJSON.value { draft.set("traits", traits) }
            submit(draft, signal: .track, completion: completion, apply: nil)
        }
    }

    func alias(_ newId: String, previousId: String?, completion: Callback?) {
        guard !newId.isEmpty else { return }
        scheduler.async { [self] in
            let draft = build("alias")
            draft.set("userId", .string(newId))
            draft.set("previousId", .string(previousId ?? identity.anonymousId()))
            submit(draft, signal: .track, completion: completion, apply: nil)
        }
    }

    func setConsent(_ input: ConsentInput) {
        scheduler.async { [self] in consent.setConsent(input) }
    }

    func setUserIdentities(_ ordered: [(String, String?)], hashed: Bool, completion: Callback?) {
        scheduler.async { [self] in
            let launch = { [self] in launchIdentityOp(ordered, hashed: hashed, completion: completion) }
            if !gatingActive {
                launch()
                return
            }
            if !consent.isResolved() {
                bufferEvent(BufferedEvent(draft: nil, signal: .identify, completion: completion, apply: launch))
                return
            }
            if consent.getSignals()?.identify == true {
                launch()
                return
            }
            logger.warn("[SDK] Dropped setUserIdentities: no identify consent")
            let error = ZeotapError.identitiesDenied
            notifyDropped(type: "identity update", reason: .consentDenied, message: error.localizedDescription)
            deliver(completion, error)
        }
    }

    func unsetUserIdentities(_ keys: [String]?) {
        scheduler.async { [self] in userIdentities.unset(keys) }
    }

    func getConsentState() -> ConsentStateSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return consentSnapshot
    }

    func anonymousId() -> String {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return anonymousIdSnapshot
    }

    func userId() -> String? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return userIdSnapshot
    }

    func reset() {
        scheduler.async { [self] in
            identity.reset()
            setSnapshots(anonymousId: identity.anonymousId(), userId: nil)
            userIdentities.clear()
            do { try eventQueue.clear() } catch { reportError(error) }
            preConsentBuffer.removeAll()
            consent.clear()
            setConsentSnapshot(.unresolved)
            consentPersistence?.clear()
            // Re-arm so a gated client can't buffer forever after logout.
            scheduleConsentDefault()
        }
    }

    func flush(completion: (() -> Void)?) {
        scheduler.async { [self] in
            if let completion { pendingFlushCompletions.append(completion) }
            doFlush(force: true)
        }
    }

    func addListener(_ listener: SdkListener) {
        snapshotLock.lock()
        listeners[ObjectIdentifier(listener)] = WeakListener(value: listener)
        snapshotLock.unlock()
    }

    func removeListener(_ listener: SdkListener) {
        snapshotLock.lock()
        listeners.removeValue(forKey: ObjectIdentifier(listener))
        snapshotLock.unlock()
    }

    // MARK: - Consent gate (client.ts 669-762)

    private func build(_ type: String) -> EventDraft {
        let draft = payloadBuilder.base(type: type, messageId: ids.uuid(), anonymousId: identity.anonymousId(), userId: identity.userId(), nowMs: clock.nowMs())
        if let current = consent.getConsent() { draft.setContext("consent", ConsentState.toJSON(current)) }
        return draft
    }

    private func setUserId(_ userId: String) {
        identity.setUserId(userId)
        setSnapshots(anonymousId: identity.anonymousId(), userId: userId)
    }

    private func submit(_ draft: EventDraft, signal: Signal, completion: Callback?, apply: (() -> Void)?) {
        if !gatingActive {
            apply?()
            enqueue(draft, completion: completion)
            return
        }
        let entry = BufferedEvent(draft: draft, signal: signal, completion: completion, apply: apply)
        if !consent.isResolved() {
            bufferEvent(entry)
            return
        }
        dispatchGated(entry)
    }

    private func bufferEvent(_ entry: BufferedEvent) {
        let what = entry.draft?.type ?? "identity update"
        if preConsentBuffer.count >= config.consent.maxBufferedEvents {
            logger.warn("[SDK] Dropped \(what): pre-consent buffer full (\(config.consent.maxBufferedEvents))")
            let error = ZeotapError.preConsentBufferFull
            notifyDropped(type: what, reason: .bufferFull, message: error.localizedDescription)
            deliver(entry.completion, error)
            return
        }
        preConsentBuffer.append(entry)
        logger.debug("[SDK] Buffered \(what) until consent resolves")
    }

    private func dispatchGated(_ entry: BufferedEvent) {
        let signals = consent.getSignals()
        let granted: Bool
        switch entry.signal {
        case .track: granted = signals?.track == true
        case .identify: granted = signals?.identify == true
        }
        if granted {
            entry.apply?()
            // Pure side-effect entries (buffered setUserIdentities) own their completion.
            guard let draft = entry.draft else { return }
            // A buffered event built before a granted identify was applied misses the userId it
            // would have carried in the ungated flow — patch it in.
            if !draft.has("userId"), let userId = identity.userId() { draft.set("userId", .string(userId)) }
            enqueue(draft, completion: entry.completion)
            return
        }
        let what = entry.draft?.type ?? "identity update"
        let error = ZeotapError.consentDenied(what: what, signal: entry.signal.rawValue)
        logger.warn(error.localizedDescription)
        notifyDropped(type: what, reason: .consentDenied, message: error.localizedDescription)
        deliver(entry.completion, error)
    }

    private func drainConsentBuffer() {
        guard !preConsentBuffer.isEmpty else { return }
        let entries = preConsentBuffer
        preConsentBuffer.removeAll()
        entries.forEach(dispatchGated)
    }

    private func onConsentResolved(_ resolution: ResolvedConsent) {
        setConsentSnapshot(ConsentStateSnapshot(resolved: true, signals: resolution.signals, source: resolution.source, gdprApplies: resolution.gdprApplies))
        drainConsentBuffer()
        if resolution.source != .storage {
            consentPersistence?.save(resolution)
        }
    }

    private func scheduleConsentDefault() {
        guard gatingActive else { return }
        consentTimer?.cancel()
        consentTimer = scheduler.schedule(after: Int64(config.consent.cmpTimeoutMs)) { [weak self] in
            guard let self else { return }
            self.consent.resolveDefault(granted: self.config.consent.default == .granted)
        }
    }

    private func cancelConsentTimer() {
        scheduler.async { [self] in consentTimer?.cancel() }
    }

    // MARK: - Identities

    private func launchIdentityOp(_ ordered: [(String, String?)], hashed: Bool, completion: Callback?) {
        userIdentities.setIdentities(ordered, hashed: hashed)
        deliver(completion, nil)
    }

    // MARK: - Queue + delivery

    private func enqueue(_ draft: EventDraft, completion: Callback?) {
        if let identities = userIdentities.get() { draft.setContext("identities", identities) }
        // Events built BEFORE consent resolved (buffered) would otherwise ship without
        // context.consent even though they were only released because consent was granted.
        if !draft.hasContext("consent"), let current = consent.getConsent() {
            draft.setContext("consent", ConsentState.toJSON(current))
        }
        do {
            try eventQueue.enqueue(messageId: draft.messageId, payload: JSONWriter.string(draft.materialise()))
            logger.debug("[SDK] Enqueued \(draft.type)")
            if try eventQueue.count() >= config.flushAt { doFlush(force: false) }
            deliver(completion, nil)
        } catch {
            logger.error("[SDK] Enqueue failed", error)
            notifyDropped(type: draft.type, reason: .enqueueFailed, message: error.localizedDescription)
            reportError(error)
            deliver(completion, error)
        }
    }

    private func trackLifecycle(_ event: LifecycleEvents.Event) {
        let draft = build("track")
        draft.set("event", .string(event.name))
        draft.set("properties", .object(event.properties))
        submit(draft, signal: .track, completion: nil, apply: nil)
    }

    private func doFlush(force: Bool, inBackground: Bool = false) {
        guard !isShutdown, !inFlight else { return }
        if !force, clock.nowMs() < nextFlushAllowedAt { return }
        let batchId = ids.uuid()
        let batch: [QueuedEvent]
        do {
            batch = try eventQueue.reserve(batchId: batchId, maxBytes: Transport.reserveMaxBytes)
        } catch {
            reportError(error)
            completeFlushes()
            return
        }
        guard !batch.isEmpty else {
            completeFlushes()
            return
        }
        inFlight = true
        var backgroundToken: BackgroundTaskToken?
        if inBackground {
            backgroundToken = backgroundTasks?.begin { [weak self] in
                // Background time expired: nothing to do here — the in-flight send either
                // completes or fails, and the reservation is released on failure.
                self?.logger.warn("[SDK] Background flush expired")
            }
        }
        transport.send(batch.map(\.payload)) { [weak self] outcome in
            guard let self else { return }
            self.inFlight = false
            switch outcome {
            case let .success(result):
                self.safeQueue { try self.eventQueue.ack(batchId: batchId) }
                self.resetBackoff()
                self.forEachListener { $0.onBatchResult(result) }
                if !result.success {
                    self.logger.warn("[SDK] Ingest accepted \(result.received)/\(result.sent) events: \(result.errors)")
                } else {
                    self.logger.debug("[SDK] Sent \(batch.count) events")
                }
                if self.safeCount() > 0 {
                    self.doFlush(force: true)
                } else {
                    self.completeFlushes()
                }
            case let .rejected(status, body):
                // Non-retryable client error: deterministic; drop (web parity).
                self.safeQueue { try self.eventQueue.ack(batchId: batchId) }
                self.logger.error("Ingest API error \(status): \(body)", nil)
                self.forEachListener { $0.onDeliveryFailure(status: status, attempts: 1, error: ZeotapError.ingestRejected(status: status, body: body)) }
                self.notifyDropped(type: "batch", reason: .ingestRejected, message: "Ingest API error \(status)")
                self.completeFlushes()
            case let .exhausted(attempts, lastStatus, description):
                self.safeQueue { try self.eventQueue.release(batchId: batchId) }
                let delay = Self.backoffMs[min(self.backoffIndex, Self.backoffMs.count - 1)]
                self.backoffIndex += 1
                self.nextFlushAllowedAt = self.clock.nowMs() + delay
                self.logger.warn("[SDK] Failed to send after \(attempts) attempts; retrying in \(delay)ms")
                let error = ZeotapError.deliveryFailed(attempts: attempts, description: description ?? "status \(lastStatus.map(String.init) ?? "none")")
                self.forEachListener { $0.onDeliveryFailure(status: lastStatus, attempts: attempts, error: error) }
                self.completeFlushes()
            }
            backgroundToken?.end()
        }
    }

    private func completeFlushes() {
        guard !pendingFlushCompletions.isEmpty else { return }
        let completions = QueueHop(pendingFlushCompletions)
        pendingFlushCompletions.removeAll()
        config.callbackQueue.async { completions.value.forEach { $0() } }
    }

    private func resetBackoff() {
        backoffIndex = 0
        nextFlushAllowedAt = 0
    }

    private func safeCount() -> Int {
        do { return try eventQueue.count() } catch {
            reportError(error)
            return 0
        }
    }

    private func safeQueue(_ block: () throws -> Void) {
        do { try block() } catch { reportError(error) }
    }

    // MARK: - Helpers

    private struct Mapped {
        let ok: Bool
        let value: JSONValue?
    }

    /// Convert host properties on the CALLER's thread (defensive copy); a bad value fails the call.
    private func mapped(_ properties: [String: Any]?, completion: Callback?) -> Mapped {
        guard let properties else { return Mapped(ok: true, value: nil) }
        do {
            return Mapped(ok: true, value: try JSONMapper.fromDictionary(properties))
        } catch {
            logger.warn(error.localizedDescription)
            deliver(completion, error)
            return Mapped(ok: false, value: nil)
        }
    }

    private func deliver(_ completion: Callback?, _ error: Error?) {
        guard let completion else { return }
        config.callbackQueue.async { completion(error) }
    }

    private func setSnapshots(anonymousId: String, userId: String?) {
        snapshotLock.lock()
        anonymousIdSnapshot = anonymousId
        userIdSnapshot = userId
        snapshotLock.unlock()
    }

    private func setConsentSnapshot(_ snapshot: ConsentStateSnapshot) {
        snapshotLock.lock()
        consentSnapshot = snapshot
        snapshotLock.unlock()
    }

    private func currentListeners() -> [SdkListener] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return listeners.values.compactMap(\.value)
    }

    private func forEachListener(_ body: @escaping (SdkListener) -> Void) {
        let targets = currentListeners()
        guard !targets.isEmpty else { return }
        let hop = QueueHop((targets, body))
        config.callbackQueue.async { hop.value.0.forEach(hop.value.1) }
    }

    private func notifyDropped(type: String, reason: DropReason, message: String) {
        forEachListener { $0.onEventDropped(type: type, reason: reason, message: message) }
    }

    private func reportError(_ error: Error) {
        forEachListener { $0.onError(error) }
    }

    /// Inter-flush backoff after an exhausted send: 30 s → 1 m → 2 m → 5 m (reset on success / network / foreground).
    private static let backoffMs: [Int64] = [30_000, 60_000, 120_000, 300_000]
}
// swiftlint:enable type_body_length
