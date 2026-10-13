import XCTest
@testable import ZeotapSDK

/// The host-supplied advertising id: precedence, withdrawal, and the fact that a value set
/// *after* the SDK has already sent an event reaches the next one.
///
/// That last part is the whole reason `DefaultContextCollector` rebuilds the device block per
/// `collect()` instead of caching it whole. Android cached it, and `setAdvertisingId` was a silent
/// no-op after the first event; these tests exist on both platforms now so the two cannot drift
/// apart again. Mirrors `AdvertisingIdProviderTest.kt` + `DefaultContextCollectorTest.kt`.
final class AdvertisingIdTests: XCTestCase {
    private final class Fixed: AdvertisingIdProvider, @unchecked Sendable {
        private let lock = NSLock()
        private let info: AdvertisingInfo?
        private var count = 0

        init(_ info: AdvertisingInfo?) {
            self.info = info
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func current() -> AdvertisingInfo? {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return info
        }
    }

    // MARK: - ManualAdvertisingIdProvider

    func testAnUnsetManualProviderYieldsNothingAndIsNotConsideredSet() {
        let manual = ManualAdvertisingIdProvider()
        XCTAssertNil(manual.current())
        XCTAssertFalse(manual.hasValue)
    }

    func testASetManualProviderYieldsTheHostsValue() {
        let manual = ManualAdvertisingIdProvider()
        manual.set(AdvertisingInfo(id: "idfa-1", trackingAuthorized: true))
        XCTAssertTrue(manual.hasValue)
        XCTAssertEqual(manual.current(), AdvertisingInfo(id: "idfa-1", trackingAuthorized: true))
    }

    func testANilIdIsStillSetItWithdrawsAPreviousValue() {
        // Withdrawing must be distinguishable from never having supplied one, or a host could
        // not revoke an id after the user opted out.
        let manual = ManualAdvertisingIdProvider()
        manual.set(AdvertisingInfo(id: "idfa-1", trackingAuthorized: true))
        manual.set(nil)
        XCTAssertTrue(manual.hasValue)
        XCTAssertNil(manual.current())
    }

    func testAProviderSeededAtConstructionCountsAsSet() {
        XCTAssertTrue(ManualAdvertisingIdProvider(AdvertisingInfo(id: "idfa", trackingAuthorized: true)).hasValue)
    }

    // MARK: - HostFirstAdvertisingIdProvider

    func testTheHostsValueWinsOverTheConfiguredProvider() {
        let delegate = Fixed(AdvertisingInfo(id: "from-att", trackingAuthorized: true))
        let manual = ManualAdvertisingIdProvider()
        let provider = HostFirstAdvertisingIdProvider(manual: manual, delegate: delegate)

        manual.set(AdvertisingInfo(id: "from-host", trackingAuthorized: true))
        XCTAssertEqual(provider.current()?.id, "from-host")
        // Not merely overridden: the delegate is never asked, so ATT is not re-read for a
        // status the host has already spoken for.
        XCTAssertEqual(delegate.calls, 0)
    }

    func testWithoutAHostValueTheConfiguredProviderIsUsed() {
        let delegate = Fixed(AdvertisingInfo(id: "from-att", trackingAuthorized: true))
        let provider = HostFirstAdvertisingIdProvider(manual: ManualAdvertisingIdProvider(), delegate: delegate)

        XCTAssertEqual(provider.current()?.id, "from-att")
        XCTAssertEqual(delegate.calls, 1)
    }

    func testAHostValueOfNilWinsTooAndSuppressesTheDelegate() {
        // An app that withdrew the id must not have ATT quietly put it back on the next payload.
        let delegate = Fixed(AdvertisingInfo(id: "from-att", trackingAuthorized: true))
        let manual = ManualAdvertisingIdProvider()
        let provider = HostFirstAdvertisingIdProvider(manual: manual, delegate: delegate)

        manual.set(nil)
        XCTAssertNil(provider.current())
        XCTAssertEqual(delegate.calls, 0)
    }

    func testNoDelegateAndNoHostValueIsSimplyNothing() {
        XCTAssertNil(HostFirstAdvertisingIdProvider(manual: ManualAdvertisingIdProvider(), delegate: nil).current())
    }

    // MARK: - Through the collector

    private func collector(_ provider: AdvertisingIdProvider) -> DefaultContextCollector {
        DefaultContextCollector(collectAdvertisingId: true, advertisingIdProvider: provider, networkMonitor: nil)
    }

    private func device(_ c: DefaultContextCollector) throws -> JSONValue {
        try XCTUnwrap(c.collect().first { $0.0 == "device" }?.1)
    }

    func testAHostSuppliedIdSetAfterTheFirstPayloadReachesTheNextOne() throws {
        let manual = ManualAdvertisingIdProvider()
        let c = collector(HostFirstAdvertisingIdProvider(manual: manual, delegate: nil))

        XCTAssertNil(try device(c)["advertisingId"])

        manual.set(AdvertisingInfo(id: "late-idfa", trackingAuthorized: true))
        XCTAssertEqual(try device(c)["advertisingId"], .string("late-idfa"))
        XCTAssertEqual(try device(c)["adTrackingEnabled"], .bool(true))
    }

    func testWithdrawingAHostSuppliedIdRemovesItFromTheNextPayload() throws {
        let manual = ManualAdvertisingIdProvider(AdvertisingInfo(id: "idfa-1", trackingAuthorized: true))
        let c = collector(HostFirstAdvertisingIdProvider(manual: manual, delegate: nil))
        XCTAssertNotNil(try device(c)["advertisingId"])

        manual.set(AdvertisingInfo(id: nil, trackingAuthorized: false))
        XCTAssertNil(try device(c)["advertisingId"])
        // The decision is still reported — that is the point of the flag.
        XCTAssertEqual(try device(c)["adTrackingEnabled"], .bool(false))
    }

    // MARK: - Through the public API, onto real payloads

    private func harness(collectAdvertisingId: Bool) -> CoreHarness {
        let manual = ManualAdvertisingIdProvider()
        return CoreHarness(
            config: CoreHarness.baseConfig { $0.collectAdvertisingId = collectAdvertisingId },
            manualAdvertisingId: manual,
            contextCollector: DefaultContextCollector(
                collectAdvertisingId: collectAdvertisingId,
                advertisingIdProvider: HostFirstAdvertisingIdProvider(manual: manual, delegate: nil),
                networkMonitor: nil
            )
        )
    }

    private func advertisingIds(_ h: CoreHarness) -> [JSONValue?] {
        h.sentEvents().map { $0["context"]?["device"]?["advertisingId"] }
    }

    func testSetAdvertisingIdTakesEffectForSubsequentEventsOnly() {
        let h = harness(collectAdvertisingId: true)
        h.core.track("Before", properties: nil, completion: nil)
        h.settle()
        h.core.setAdvertisingId("gaid-late", trackingAuthorized: true)
        h.core.track("After", properties: nil, completion: nil)
        h.settle()
        h.flushAndSettle()

        // The already-built payload is untouched; the next one carries the id. Event bytes are
        // frozen at enqueue, so a late setter can never rewrite history.
        XCTAssertEqual(advertisingIds(h), [nil, .string("gaid-late")])
    }

    func testSetAdvertisingIdIsALoudNoOpWhenCollectionIsOff() {
        let h = harness(collectAdvertisingId: false)
        h.core.setAdvertisingId("gaid-late", trackingAuthorized: true)
        h.core.track("After", properties: nil, completion: nil)
        h.settle()
        h.flushAndSettle()

        XCTAssertEqual(advertisingIds(h), [nil])
        // Loud, because a silent no-op is exactly the legacy behaviour this SDK exists to
        // remove: an app shipping in the belief it had set an id that was never sent.
        XCTAssertTrue(
            h.logger.warns.contains { $0.contains("collectAdvertisingId") },
            "expected a warning naming the flag, got \(h.logger.warns)"
        )
    }
}
