import XCTest
@testable import ZeotapSDK

/// Mirror of the `TcfIntegration` half of `sdk/js/src/tcf.test.ts` mapped onto the IABTCF_* timing
/// model: a real `ConsentManager`, a `FakeTcfDefaults` standing in for the CMP SDK and a
/// `FakeScheduler` for virtual time. Everything the integration does happens on its queue.
final class TcfAppsIntegrationTests: XCTestCase {
    private static let vendorBits = String(repeating: "0", count: TcfTranslator.zeotapGVLId - 1) + "1"
    /// Purposes 1, 3, 4, 9 consented.
    private static let purposeBits = "101100001"

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private final class Harness {
        let queue: DispatchQueue
        let clock: FakeClock
        let scheduler: FakeScheduler
        let consent: ConsentManager
        let defaults: FakeTcfDefaults
        let logger: RecordingLogger
        let detected: Counter
        let listenerCalls: Counter
        let integration: TcfAppsIntegration

        init(_ data: TcData = .empty, cmpTimeoutMs: Int = 10_000, configure: (inout ConsentOptions) -> Void = { _ in }) {
            let queue = DispatchQueue(label: "com.zeotap.sdk.test.tcf")
            let clock = FakeClock(nowMs: fixedNowMs)
            let scheduler = FakeScheduler(queue: queue, clock: clock)
            let consent = ConsentManager(clock: clock)
            let defaults = FakeTcfDefaults(data)
            let logger = RecordingLogger()
            let detected = Counter()
            let listenerCalls = Counter()
            var options = ConsentOptions()
            options.require = true
            options.cmpTimeoutMs = cmpTimeoutMs
            configure(&options)
            consent.onResolve { _ in listenerCalls.bump() }

            self.queue = queue
            self.clock = clock
            self.scheduler = scheduler
            self.consent = consent
            self.defaults = defaults
            self.logger = logger
            self.detected = detected
            self.listenerCalls = listenerCalls
            integration = TcfAppsIntegration(
                defaults: defaults,
                consent: consent,
                options: options,
                scheduler: scheduler,
                clock: clock,
                logger: logger,
                onDetected: { detected.bump() }
            )
        }

        func start() { queue.sync { integration.start() } }
        func stop() { queue.sync { integration.stop() } }

        /// Run posted work, advance virtual time (firing timers on the queue), run posted work again.
        func advance(_ ms: Int64) {
            scheduler.runPending()
            scheduler.advance(by: ms)
            scheduler.runPending()
        }

        func settle() { scheduler.runPending() }
    }

    private func answered(gdprApplies: Bool? = true, purposes: String? = TcfAppsIntegrationTests.purposeBits, vendors: String? = TcfAppsIntegrationTests.vendorBits, tcString: String? = "TC-STRING") -> TcData {
        TcData(cmpSdkId: 7, gdprApplies: gdprApplies, tcString: tcString, purposeConsents: purposes, vendorConsents: vendors)
    }

    // MARK: detection

    func testDetectsACmpThatAppearsAfterAFewPollsAndObservesIt() {
        let h = Harness()
        h.start()
        XCTAssertEqual(h.detected.count, 0)

        h.advance(3_000)
        XCTAssertEqual(h.detected.count, 0)
        h.defaults.set(TcData(cmpSdkId: 7, gdprApplies: true))
        h.advance(1_000)

        XCTAssertEqual(h.detected.count, 1)
        XCTAssertEqual(h.defaults.observerCount, 1)
        XCTAssertFalse(h.consent.isResolved(), "present but silent → still pending")
        XCTAssertTrue(h.logger.debugs.contains("[SDK] TCF CMP detected"))
    }

    func testDetectsImmediatelyWhenTheDefaultsAreAlreadyPresent() {
        let h = Harness(TcData(cmpSdkId: 7))
        h.start()
        XCTAssertEqual(h.detected.count, 1)
        XCTAssertEqual(h.defaults.observerCount, 1)
    }

    func testGivesUpSilentlyWhenNoCmpAppearsWithinTheBudget() {
        let h = Harness(cmpTimeoutMs: 5_000)
        h.start()
        h.advance(20_000)
        XCTAssertEqual(h.detected.count, 0)
        XCTAssertFalse(h.consent.isResolved(), "the core's default timer decides")
        XCTAssertEqual(h.defaults.observerCount, 0)
        XCTAssertEqual(h.scheduler.pendingTimerCount, 0, "polling stopped")
        XCTAssertTrue(h.logger.debugs.contains("[SDK] No TCF CMP found within budget"))

        // A CMP that shows up after the budget is ignored.
        h.defaults.set(TcData(cmpSdkId: 7, gdprApplies: true))
        h.advance(5_000)
        XCTAssertEqual(h.detected.count, 0)
    }

    func testPollBudgetIsCeilOfTimeoutOverOneSecondWithAtLeastOneAttempt() {
        // 2500 ms → 3 attempts at 0, 1000, 2000 — a CMP appearing at 2000 is still found.
        let h = Harness(cmpTimeoutMs: 2_500)
        h.start()
        h.advance(1_500)
        h.defaults.set(TcData(cmpSdkId: 7, gdprApplies: true))
        h.advance(500)
        XCTAssertEqual(h.detected.count, 1)

        // 1 ms → a single immediate attempt, no timer.
        let single = Harness(cmpTimeoutMs: 1)
        single.start()
        XCTAssertEqual(single.scheduler.pendingTimerCount, 0)
        XCTAssertEqual(single.detected.count, 0)
    }

    // MARK: evaluation

    func testTcStringResolvesViaOfferWithSourceCmpAndTheTcString() throws {
        let h = Harness(answered())
        h.start()

        let resolution = try XCTUnwrap(h.consent.getResolution())
        XCTAssertEqual(resolution.source, .cmp)
        XCTAssertEqual(resolution.tcfString, "TC-STRING")
        XCTAssertEqual(resolution.gdprApplies, true)
        XCTAssertEqual(resolution.signals, ConsentSignals(track: true, identify: true, cookieSync: true))
        XCTAssertNil(resolution.input)
        XCTAssertEqual(resolution.ts, fixedNowMs)
        XCTAssertEqual(h.consent.getConsent(), .tcf(tcfString: "TC-STRING"), "payload context surfaces the raw string")
        XCTAssertEqual(h.defaults.observerCount, 1, "observation stays for later consent changes")
        XCTAssertEqual(h.scheduler.pendingTimerCount, 0, "no ping armed")
    }

    func testGdprApplyingWithoutVendorConsentTranslatesDenials() {
        let h = Harness(answered(purposes: "1", vendors: nil))
        h.start()
        XCTAssertEqual(h.consent.getSignals(), ConsentSignals(track: false, identify: false, cookieSync: false))
        XCTAssertEqual(h.consent.getResolution()?.tcfString, "TC-STRING")
    }

    func testGdprNotApplyingGrantsEverythingWithoutTheTcStringAndStopsObserving() throws {
        let h = Harness(answered(gdprApplies: false))
        h.start()

        let resolution = try XCTUnwrap(h.consent.getResolution())
        XCTAssertEqual(resolution.signals, .uniform(true))
        XCTAssertEqual(resolution.gdprApplies, false)
        XCTAssertNil(resolution.tcfString)
        XCTAssertEqual(resolution.source, .cmp)
        XCTAssertNil(h.consent.getConsent())
        XCTAssertEqual(h.defaults.observerCount, 0, "observation cancelled")
        XCTAssertEqual(h.scheduler.pendingTimerCount, 0)

        // Later writes change nothing.
        h.defaults.set(answered(gdprApplies: true, purposes: ""))
        h.advance(1_000)
        XCTAssertEqual(h.consent.getSignals(), .uniform(true))
        XCTAssertEqual(h.listenerCalls.count, 1)
    }

    func testCmpPresentWithoutAnswerKeepsWaitingThenResolvesAndCanReResolve() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        XCTAssertFalse(h.consent.isResolved())
        XCTAssertTrue(h.logger.debugs.contains("[SDK] TCF pending"))

        // The CMP answers 2 s later — the change is observed, debounced 300 ms, then evaluated.
        h.advance(2_000)
        h.defaults.set(answered())
        h.advance(299)
        XCTAssertFalse(h.consent.isResolved())
        h.advance(1)
        XCTAssertEqual(h.consent.getSignals(), .uniform(true))
        XCTAssertEqual(h.consent.getResolution()?.tcfString, "TC-STRING")

        // A later consent change (revoke) re-resolves through the same observation.
        h.defaults.set(answered(purposes: "", tcString: "TC-2"))
        h.advance(300)
        XCTAssertEqual(h.consent.getSignals()?.track, false)
        XCTAssertEqual(h.consent.getResolution()?.tcfString, "TC-2")
        XCTAssertEqual(h.listenerCalls.count, 2)

        // The ping backstop armed while pending was cancelled by the answer.
        h.advance(20_000)
        XCTAssertEqual(h.listenerCalls.count, 2)
    }

    func testATcStringWithoutPurposeConsentsIsNotAnAnswer() {
        let h = Harness(answered(purposes: nil))
        h.start()
        XCTAssertFalse(h.consent.isResolved())
        h.defaults.set(answered(purposes: ""))
        h.advance(300)
        XCTAssertTrue(h.consent.isResolved())
        XCTAssertEqual(h.consent.getSignals(), .uniform(false))
    }

    // MARK: ping backstop

    func testCmpThatNeverAnswersIsDeniedAfterTheBudgetWhenGdprAppliesIsUnknown() throws {
        let h = Harness(TcData(cmpSdkId: 7))
        h.start()
        h.advance(9_999)
        XCTAssertFalse(h.consent.isResolved())
        h.advance(1)

        let resolution = try XCTUnwrap(h.consent.getResolution())
        XCTAssertEqual(resolution.signals, .uniform(false))
        XCTAssertEqual(resolution.source, .cmp)
        XCTAssertNil(resolution.gdprApplies)
        XCTAssertNil(resolution.tcfString)
        XCTAssertTrue(h.logger.debugs.contains("[SDK] TCF CMP never answered; resolving by gdprApplies"))
    }

    func testCmpThatNeverAnswersIsDeniedUnderGdpr() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        h.advance(10_000)
        XCTAssertEqual(h.consent.getSignals(), .uniform(false))
        XCTAssertEqual(h.consent.getResolution()?.gdprApplies, true)
        XCTAssertEqual(h.consent.getResolution()?.source, .cmp)
    }

    func testCmpThatNeverAnswersGrantsWhenGdprDoesNotApplyAtPingTime() {
        let h = Harness(TcData(cmpSdkId: 7))
        h.start()
        // The CMP flips gdprApplies without a change notification the integration sees.
        h.defaults.set(TcData(cmpSdkId: 7, gdprApplies: false), notify: false)
        h.advance(10_000)
        XCTAssertEqual(h.consent.getSignals(), .uniform(true))
        XCTAssertEqual(h.consent.getResolution()?.gdprApplies, false)
        XCTAssertEqual(h.defaults.observerCount, 0)
    }

    func testAnAnswerLandingRightAtPingTimeIsTranslated() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        h.defaults.set(answered(), notify: false)
        h.advance(10_000)
        XCTAssertEqual(h.consent.getSignals(), .uniform(true))
        XCTAssertEqual(h.consent.getResolution()?.tcfString, "TC-STRING")
    }

    func testThePingIsArmedOnlyOnce() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        // Repeated silent writes re-evaluate to "pending" but must not push the backstop out.
        h.advance(4_000)
        h.defaults.set(TcData(cmpSdkId: 8, gdprApplies: true))
        h.advance(4_000)
        h.defaults.set(TcData(cmpSdkId: 9, gdprApplies: true))
        h.advance(2_000)
        XCTAssertTrue(h.consent.isResolved(), "ping fired at start + 10 s regardless of later changes")
        XCTAssertEqual(h.consent.getSignals(), .uniform(false))
    }

    // MARK: precedence, debounce, stop

    func testAManualSetConsentBeatsALaterCmpResolution() {
        let h = Harness(answered())
        h.queue.sync { h.consent.setConsent(.parsed(ParsedConsent(analytics: false))) }
        h.start()
        XCTAssertEqual(h.consent.getResolution()?.source, .manual)
        XCTAssertEqual(h.consent.getSignals()?.track, false)
        XCTAssertEqual(h.listenerCalls.count, 1)

        // And a CMP change afterwards is still rejected.
        h.defaults.set(answered(tcString: "TC-3"))
        h.advance(300)
        XCTAssertEqual(h.consent.getResolution()?.source, .manual)
    }

    func testBurstsOfDefaultsWritesCoalesceIntoOneEvaluation() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        h.defaults.set(answered(tcString: "A"))
        h.defaults.set(answered(tcString: "B"))
        h.settle()
        h.advance(200)
        h.defaults.set(answered(tcString: "C"))
        h.advance(299)
        XCTAssertFalse(h.consent.isResolved(), "debounce restarted by the last write")
        h.advance(1)
        XCTAssertEqual(h.listenerCalls.count, 1)
        XCTAssertEqual(h.consent.getResolution()?.tcfString, "C")
    }

    func testStopCancelsPollingBeforeDetection() {
        let h = Harness()
        h.start()
        h.advance(1_000)
        h.stop()
        h.defaults.set(TcData(cmpSdkId: 7, gdprApplies: true))
        h.advance(10_000)
        XCTAssertEqual(h.detected.count, 0)
        XCTAssertEqual(h.scheduler.pendingTimerCount, 0)
    }

    func testStopCancelsThePingDebounceAndObservationAfterDetection() {
        let h = Harness(TcData(cmpSdkId: 7, gdprApplies: true))
        h.start()
        h.defaults.set(answered())
        h.settle()
        h.stop()
        XCTAssertEqual(h.defaults.observerCount, 0)
        XCTAssertEqual(h.scheduler.pendingTimerCount, 0)
        h.advance(20_000)
        XCTAssertFalse(h.consent.isResolved())

        // Later writes reach no observer.
        h.defaults.set(answered(tcString: "late"))
        h.advance(1_000)
        XCTAssertFalse(h.consent.isResolved())
    }
}
