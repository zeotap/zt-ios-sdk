import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/consent.test.ts` and the "ConsentManager resolution machine" half of
/// `consent-state.test.ts`.
final class ConsentManagerTests: XCTestCase {
    private let clock = FakeClock(nowMs: 1_700_000_000_000)

    private func make() -> ConsentManager { ConsentManager(clock: clock) }

    private func parsed(_ analytics: Bool? = nil, marketing: Bool? = nil, advertising: Bool? = nil, functional: Bool? = nil) -> ConsentInput {
        .parsed(ParsedConsent(analytics: analytics, marketing: marketing, advertising: advertising, functional: functional))
    }

    // MARK: consent.test.ts

    func testGetConsentIsNilInitially() {
        XCTAssertNil(make().getConsent())
    }

    func testSetConsentWithTcfStringStoresIt() {
        let cm = make()
        cm.setConsent(.tcf(tcfString: "CPXxRfAPXxRfAAfKAB"))
        XCTAssertEqual(cm.getConsent(), .tcf(tcfString: "CPXxRfAPXxRfAAfKAB"))
    }

    func testSetConsentWithUsPrivacyStringStoresIt() {
        let cm = make()
        cm.setConsent(.usPrivacy("1YNN"))
        XCTAssertEqual(cm.getConsent(), .usPrivacy("1YNN"))
    }

    func testSetConsentWithParsedCategoriesStoresThem() {
        let cm = make()
        cm.setConsent(parsed(true, marketing: false))
        XCTAssertEqual(cm.getConsent(), parsed(true, marketing: false))
    }

    func testSetConsentReplacesPreviousStateEntirely() {
        let cm = make()
        cm.setConsent(.tcf(tcfString: "CPXxRfAPXxRfAAfKAB"))
        cm.setConsent(.usPrivacy("1YNN"))
        XCTAssertEqual(cm.getConsent(), .usPrivacy("1YNN"))
        XCTAssertNil(cm.getResolution()?.tcfString, "no tcfString carried over")

        cm.setConsent(.tcf(tcfString: "CPXxRfAPXxRfAAfKAB"))
        cm.setConsent(parsed(true, functional: true))
        XCTAssertEqual(cm.getConsent(), parsed(true, functional: true))
        XCTAssertNil(cm.getResolution()?.tcfString)
    }

    func testClearResetsConsentToNil() {
        let cm = make()
        cm.setConsent(.tcf(tcfString: "CPXxRfAPXxRfAAfKAB"))
        cm.clear()
        XCTAssertNil(cm.getConsent())
        XCTAssertFalse(cm.isResolved())
        XCTAssertNil(cm.getResolution())
    }

    func testFullParsedConsentRoundTrip() throws {
        let cm = make()
        cm.setConsent(parsed(true, marketing: false, advertising: false, functional: true))
        guard case let .parsed(state)? = cm.getConsent() else { return XCTFail("expected parsed") }
        XCTAssertEqual(state.analytics, true)
        XCTAssertEqual(state.marketing, false)
        XCTAssertEqual(state.advertising, false)
        XCTAssertEqual(state.functional, true)
    }

    // MARK: resolution machine (consent-state.test.ts)

    func testStartsUnresolved() {
        let mgr = make()
        XCTAssertFalse(mgr.isResolved())
        XCTAssertNil(mgr.getSignals())
        XCTAssertNil(mgr.getConsent())
        XCTAssertNil(mgr.getResolution())
    }

    func testSetConsentResolvesAsManualAndFiresListeners() {
        let mgr = make()
        var received: [ResolvedConsent] = []
        mgr.onResolve { received.append($0) }

        mgr.setConsent(parsed(true, advertising: true))
        XCTAssertTrue(mgr.isResolved())
        XCTAssertEqual(mgr.getResolution()?.source, .manual)
        XCTAssertEqual(mgr.getSignals(), ConsentSignals(track: true, identify: true, cookieSync: true))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.ts, 1_700_000_000_000, "ts comes from the clock")
        XCTAssertNil(received.first?.gdprApplies)
        XCTAssertEqual(received.first?.input, parsed(true, advertising: true))
    }

    func testCapturesTcfStringFromAManualTcfInput() {
        let mgr = make()
        mgr.setConsent(.tcf(tcfString: "CO123"))
        XCTAssertEqual(mgr.getResolution()?.tcfString, "CO123")
        XCTAssertEqual(mgr.getConsent(), .tcf(tcfString: "CO123"))
    }

    func testAWeakerSourceCannotReplaceAStrongerOne() {
        let mgr = make()
        mgr.setConsent(parsed(false)) // manual, track denied
        let accepted = mgr.offer(ResolvedConsent(signals: .uniform(true), source: .storage, ts: 1))
        XCTAssertFalse(accepted)
        XCTAssertEqual(mgr.getSignals()?.track, false)
        XCTAssertFalse(mgr.offer(ResolvedConsent(signals: .uniform(true), source: .cmp, ts: 2)))
        XCTAssertFalse(mgr.offer(ResolvedConsent(signals: .uniform(true), source: .default, ts: 3)))
        XCTAssertEqual(mgr.getResolution()?.source, .manual)
    }

    func testCmpOverridesStorageAndCmpReResolvesCmp() {
        let mgr = make()
        XCTAssertTrue(mgr.offer(ResolvedConsent(signals: .uniform(true), source: .storage, ts: 1)))
        XCTAssertTrue(mgr.offer(ResolvedConsent(signals: .uniform(false), source: .cmp, ts: 2)))
        XCTAssertEqual(mgr.getSignals()?.track, false)
        // Same-source re-resolution (CMP consent change) is accepted.
        XCTAssertTrue(mgr.offer(ResolvedConsent(signals: .uniform(true), source: .cmp, ts: 3)))
        XCTAssertEqual(mgr.getSignals()?.track, true)
        XCTAssertEqual(mgr.getResolution()?.ts, 3, "offer() carries its own ts")
    }

    func testManualSetConsentReplacesACmpResolution() {
        let mgr = make()
        mgr.offer(ResolvedConsent(signals: .uniform(true), tcfString: "TC", gdprApplies: true, source: .cmp, ts: 1))
        mgr.setConsent(parsed(false))
        XCTAssertEqual(mgr.getResolution()?.source, .manual)
        XCTAssertEqual(mgr.getSignals()?.track, false)
        XCTAssertNil(mgr.getResolution()?.tcfString, "replaced entirely, not merged")
        XCTAssertNil(mgr.getResolution()?.gdprApplies)
    }

    func testResolveDefaultOnlyFiresWhileUnresolved() {
        let mgr = make()
        mgr.resolveDefault(granted: false)
        XCTAssertEqual(mgr.getResolution()?.source, .default)
        XCTAssertEqual(mgr.getSignals()?.track, false)
        XCTAssertNil(mgr.getConsent())
        XCTAssertEqual(mgr.getResolution()?.ts, 1_700_000_000_000)

        let mgr2 = make()
        mgr2.setConsent(parsed(true))
        mgr2.resolveDefault(granted: false)
        XCTAssertEqual(mgr2.getResolution()?.source, .manual)
        XCTAssertEqual(mgr2.getSignals()?.track, true)

        // A default is the weakest source: storage may still replace it, but not the other way round.
        XCTAssertTrue(mgr.offer(ResolvedConsent(signals: .uniform(true), source: .storage, ts: 5)))
        XCTAssertFalse(mgr.offer(ResolvedConsent(signals: .uniform(false), source: .default, ts: 6)))
        XCTAssertEqual(mgr.getResolution()?.source, .storage)
    }

    func testClearReturnsToUnresolvedButKeepsListeners() {
        let mgr = make()
        var calls = 0
        mgr.onResolve { _ in calls += 1 }
        mgr.setConsent(parsed(true))
        mgr.clear()
        XCTAssertFalse(mgr.isResolved())
        XCTAssertEqual(calls, 1)

        mgr.setConsent(parsed(true))
        XCTAssertEqual(calls, 2)
    }

    func testACmpResolutionWithoutInputSurfacesAsTcfStringForPayloads() {
        let mgr = make()
        mgr.offer(ResolvedConsent(signals: .uniform(true), tcfString: "CO-CMP", gdprApplies: true, source: .cmp, ts: 1))
        XCTAssertEqual(mgr.getConsent(), .tcf(tcfString: "CO-CMP"))
        XCTAssertEqual(mgr.getResolution()?.gdprApplies, true)
    }

    func testACmpResolutionWithoutTcStringHasNoConsentInput() {
        let mgr = make()
        mgr.offer(ResolvedConsent(signals: .uniform(true), gdprApplies: false, source: .cmp, ts: 1))
        XCTAssertNil(mgr.getConsent())
        mgr.offer(ResolvedConsent(signals: .uniform(true), tcfString: "", gdprApplies: true, source: .cmp, ts: 2))
        XCTAssertNil(mgr.getConsent(), "empty tcfString does not surface")
    }

    func testHydratedStorageResolutionKeepsItsInput() {
        let mgr = make()
        mgr.offer(ResolvedConsent(signals: .uniform(true), input: parsed(advertising: true), source: .storage, ts: 1_699_913_600_000))
        XCTAssertEqual(mgr.getConsent(), parsed(advertising: true))
        XCTAssertEqual(mgr.getResolution()?.ts, 1_699_913_600_000)
    }

    func testListenersReceiveEveryAcceptedResolutionAndNotRejectedOnes() {
        let mgr = make()
        var sources: [ConsentSource] = []
        mgr.onResolve { sources.append($0.source) }
        mgr.offer(ResolvedConsent(signals: .uniform(true), source: .storage, ts: 1))
        mgr.offer(ResolvedConsent(signals: .uniform(true), source: .cmp, ts: 2))
        mgr.offer(ResolvedConsent(signals: .uniform(true), source: .storage, ts: 3)) // rejected
        mgr.setConsent(parsed(true))
        mgr.resolveDefault(granted: false) // no-op
        XCTAssertEqual(sources, [.storage, .cmp, .manual])
    }
}
