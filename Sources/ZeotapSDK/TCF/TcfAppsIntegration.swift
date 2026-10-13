import Foundation

/// The web `__tcfapi` timing model (`tcf.ts` `TcfIntegration`) mapped onto the `IABTCF_*` defaults:
/// poll for a CMP every second within the budget (never found → silent, the core's default timer
/// decides); found → `onDetected()`, observe changes (debounced 300 ms) and evaluate:
/// `gdprApplies == false` grants everything without a TC string and stops observing; a TC string
/// with purpose consents translates (and re-translates on later changes); a present-but-silent CMP
/// is given one more budget window, then resolved by `gdprApplies` (fail closed under GDPR — a nil
/// `gdprApplies` denies). Every offer has source `.cmp`.
///
/// All state lives on the scheduler's queue: `start()`/`stop()` must be called on it, timers fire
/// on it, and defaults-change callbacks hop onto it via `scheduler.async`.
final class TcfAppsIntegration {
    static let pollIntervalMs: Int64 = 1_000
    static let debounceMs: Int64 = 300

    private let defaults: TcfDefaults
    private let consent: ConsentManager
    private let options: ConsentOptions
    private let scheduler: Scheduler
    private let clock: Clock
    private let logger: Logger
    private let onDetected: () -> Void

    private var pollTask: ScheduledTask?
    private var pingTask: ScheduledTask?
    private var debounceTask: ScheduledTask?
    private var observation: ObservationToken?
    private var pingArmed = false
    private var stopped = false

    init(
        defaults: TcfDefaults,
        consent: ConsentManager,
        options: ConsentOptions,
        scheduler: Scheduler,
        clock: Clock,
        logger: Logger,
        onDetected: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.consent = consent
        self.options = options
        self.scheduler = scheduler
        self.clock = clock
        self.logger = logger
        self.onDetected = onDetected
    }

    /// Begin CMP detection: read the defaults now, then every second within `cmpTimeoutMs`.
    func start() {
        let budget = Double(options.cmpTimeoutMs) / Double(TcfAppsIntegration.pollIntervalMs)
        let maxAttempts = max(1, Int(budget.rounded(.up)))
        poll(attempts: 0, maxAttempts: maxAttempts)
    }

    /// Cancel polling, the ping backstop and any pending re-evaluation; stop observing.
    func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        cancelPing()
        debounceTask?.cancel()
        debounceTask = nil
        stopObserving()
    }

    // MARK: - Detection

    private func poll(attempts: Int, maxAttempts: Int) {
        if stopped { return }
        if defaults.read().cmpPresent {
            detected()
            return
        }
        let next = attempts + 1
        if next >= maxAttempts {
            logger.debug("[SDK] No TCF CMP found within budget")
            return // the core's default timer decides
        }
        pollTask = scheduler.schedule(after: TcfAppsIntegration.pollIntervalMs) { [weak self] in
            self?.poll(attempts: next, maxAttempts: maxAttempts)
        }
    }

    private func detected() {
        logger.debug("[SDK] TCF CMP detected")
        onDetected()
        observation = defaults.observe { [weak self] in
            guard let self else { return }
            self.scheduler.async { [weak self] in self?.onDefaultsChanged() }
        }
        evaluate()
    }

    /// On the core queue; coalesces bursts of `IABTCF_*` writes into one evaluation.
    private func onDefaultsChanged() {
        if stopped { return }
        debounceTask?.cancel()
        debounceTask = scheduler.schedule(after: TcfAppsIntegration.debounceMs) { [weak self] in
            self?.debounceTask = nil
            self?.evaluate()
        }
    }

    // MARK: - Evaluation

    private func evaluate() {
        if stopped { return }
        let data = defaults.read()
        if data.gdprApplies == false {
            // GDPR does not apply — everything is granted; the TC string is irrelevant.
            cancelPing()
            debounceTask?.cancel()
            debounceTask = nil
            stopObserving()
            offer(.uniform(true), tcfString: nil, gdprApplies: false)
        } else if TcfAppsIntegration.isAnswered(data) {
            // Resolved now or previously. The observation stays so a later consent change
            // re-resolves (offer() accepts same-source re-resolutions).
            cancelPing()
            offer(TcfTranslator.translate(data, options: options), tcfString: data.tcString, gdprApplies: true)
        } else {
            logger.debug("[SDK] TCF pending")
            armPing()
        }
    }

    private static func isAnswered(_ data: TcData) -> Bool {
        guard let tcString = data.tcString, !tcString.isEmpty else { return false }
        return data.purposeConsents != nil
    }

    /// Fail-closed backstop, armed once: a CMP that is present but never answers within another budget window.
    private func armPing() {
        if pingArmed { return }
        pingArmed = true
        pingTask = scheduler.schedule(after: Int64(options.cmpTimeoutMs)) { [weak self] in
            self?.pingTask = nil
            self?.ping()
        }
    }

    private func ping() {
        if stopped { return }
        let data = defaults.read()
        if data.gdprApplies == false || TcfAppsIntegration.isAnswered(data) {
            evaluate()
        } else {
            logger.debug("[SDK] TCF CMP never answered; resolving by gdprApplies")
            offer(.uniform(data.gdprApplies == false), tcfString: nil, gdprApplies: data.gdprApplies)
        }
    }

    private func offer(_ signals: ConsentSignals, tcfString: String?, gdprApplies: Bool?) {
        consent.offer(ResolvedConsent(
            signals: signals,
            input: nil,
            tcfString: tcfString,
            gdprApplies: gdprApplies,
            source: .cmp,
            ts: clock.nowMs()
        ))
        logger.debug("[SDK] TCF consent resolved track=\(signals.track) identify=\(signals.identify) cookieSync=\(signals.cookieSync)")
    }

    private func cancelPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func stopObserving() {
        observation?.cancel()
        observation = nil
    }
}
