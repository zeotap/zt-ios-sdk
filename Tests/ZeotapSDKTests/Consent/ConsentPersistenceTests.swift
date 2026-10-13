import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/consent-persistence.test.ts` — record round-trip, the TC-string side key,
/// expiry, corruption handling and skip-unchanged writes — asserting the exact persisted strings.
final class ConsentPersistenceTests: XCTestCase {
    private let keys = Keys(namespace: "zeotap")
    private let nowMs: Int64 = 1_700_000_000_000
    private let dayMs: Int64 = 86_400_000

    private func make(expiryDays: Int = 365, storage: InMemoryStore = InMemoryStore()) -> (ConsentPersistence, InMemoryStore, FakeClock) {
        let clock = FakeClock(nowMs: nowMs)
        return (ConsentPersistence(keys: keys, storage: storage, expiryDays: expiryDays, clock: clock), storage, clock)
    }

    private func resolution(
        signals: ConsentSignals = ConsentSignals(track: true, identify: true, cookieSync: false),
        input: ConsentInput? = .parsed(ParsedConsent(analytics: true)),
        tcfString: String? = nil,
        gdprApplies: Bool? = nil,
        source: ConsentSource = .manual,
        ts: Int64 = 1000
    ) -> ResolvedConsent {
        ResolvedConsent(signals: signals, input: input, tcfString: tcfString, gdprApplies: gdprApplies, source: source, ts: ts)
    }

    func testSaveLoadRoundTripsAParsedResolutionWithSourceStorage() throws {
        let (persistence, storage, _) = make()
        persistence.save(resolution())

        XCTAssertEqual(
            storage.get(keys.consent),
            "{\"v\":1,\"signals\":{\"track\":true,\"identify\":true,\"cookieSync\":false},"
                + "\"input\":{\"analytics\":true},\"source\":\"manual\",\"ts\":1000,\"exp\":\(nowMs + 365 * dayMs)}"
        )
        XCTAssertNil(storage.get(keys.consentTcf))

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.source, .storage)
        XCTAssertEqual(loaded.signals, ConsentSignals(track: true, identify: true, cookieSync: false))
        XCTAssertEqual(loaded.input, .parsed(ParsedConsent(analytics: true)))
        XCTAssertEqual(loaded.ts, 1000, "original ts, not the load time")
        XCTAssertNil(loaded.tcfString)
        XCTAssertNil(loaded.gdprApplies)
    }

    func testKeepsTheTcStringOutOfTheMainRecordAndInTheSideKey() throws {
        let (persistence, storage, _) = make()
        persistence.save(resolution(input: .tcf(tcfString: "TC-BIG"), tcfString: "TC-BIG", gdprApplies: true))

        let main = try XCTUnwrap(storage.get(keys.consent))
        XCTAssertFalse(main.contains("TC-BIG"))
        XCTAssertEqual(
            main,
            "{\"v\":1,\"signals\":{\"track\":true,\"identify\":true,\"cookieSync\":false},"
                + "\"gdprApplies\":true,\"source\":\"manual\",\"ts\":1000,\"exp\":\(nowMs + 365 * dayMs)}"
        )
        XCTAssertEqual(storage.get(keys.consentTcf), "{\"v\":1,\"tcfString\":\"TC-BIG\",\"ts\":\(nowMs),\"exp\":\(nowMs + 365 * dayMs)}")
        XCTAssertEqual(storage.writes, 2)

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.tcfString, "TC-BIG")
        XCTAssertEqual(loaded.gdprApplies, true)
        XCTAssertNil(loaded.input, "the {tcfString} input is stripped from the main record")
    }

    func testCmpResolutionRecordShape() {
        let (persistence, storage, _) = make()
        persistence.save(resolution(
            signals: ConsentSignals(track: true, identify: false, cookieSync: false),
            input: nil, tcfString: "CQ.cmp", gdprApplies: true, source: .cmp, ts: 1_699_999_999_995
        ))
        XCTAssertEqual(
            storage.get(keys.consent),
            "{\"v\":1,\"signals\":{\"track\":true,\"identify\":false,\"cookieSync\":false},\"gdprApplies\":true,\"source\":\"cmp\",\"ts\":1699999999995,\"exp\":1731536000000}"
        )
        XCTAssertEqual(storage.get(keys.consentTcf), "{\"v\":1,\"tcfString\":\"CQ.cmp\",\"ts\":1700000000000,\"exp\":1731536000000}")
    }

    func testReturnsNilAndRemovesAnExpiredRecord() {
        let (persistence, storage, clock) = make(expiryDays: 1)
        persistence.save(resolution(tcfString: "TC"))
        clock.advance(byMs: 2 * dayMs)

        XCTAssertNil(persistence.load())
        XCTAssertNil(storage.get(keys.consent))
        XCTAssertNil(storage.get(keys.consentTcf), "both keys removed")
    }

    func testExpEqualToNowIsExpired() {
        let (persistence, storage, clock) = make(expiryDays: 1)
        persistence.save(resolution())
        clock.advance(byMs: dayMs - 1)
        XCTAssertNotNil(persistence.load())
        clock.advance(byMs: 1)
        XCTAssertNil(persistence.load())
        XCTAssertNil(storage.get(keys.consent))
    }

    func testReturnsNilAndRemovesACorruptedRecord() {
        // Malformed, wrong version, missing signals, missing expiry — every shape
        // `load()` must treat as absent rather than trust.
        let unusable = [
            "{not json",
            "[1,2]",
            "\"str\"",
            "{\"v\":2,\"signals\":{\"track\":true},\"exp\":9999999999999}",
            "{\"v\":1,\"signals\":{\"track\":true}}",
            "{\"v\":1,\"exp\":9999999999999}"
        ]
        for raw in unusable {
            let storage = InMemoryStore([keys.consent: raw, keys.consentTcf: "{\"v\":1,\"tcfString\":\"TC\",\"ts\":1,\"exp\":9999999999999}"])
            let (persistence, _, _) = make(storage: storage)
            XCTAssertNil(persistence.load(), raw)
            XCTAssertNil(storage.get(keys.consent), raw)
            XCTAssertNil(storage.get(keys.consentTcf), "side key removed too: \(raw)")
        }
    }

    func testSkipsTheWriteWhenTheDecisionIsUnchanged() {
        let (persistence, storage, clock) = make()
        persistence.save(resolution())
        XCTAssertEqual(storage.writes, 1)
        let firstRecord = storage.get(keys.consent)

        clock.advance(byMs: 60_000)
        persistence.save(resolution(ts: 2000)) // same decision, later ts
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(storage.get(keys.consent), firstRecord, "exp is NOT refreshed")

        persistence.save(resolution(signals: .uniform(false)))
        XCTAssertEqual(storage.writes, 2)
    }

    func testAChangedTcStringOrGdprFlagIsAChange() {
        let (persistence, storage, _) = make()
        persistence.save(resolution(input: nil, tcfString: "CQ.a", gdprApplies: true, source: .cmp))
        XCTAssertEqual(storage.writes, 2)
        persistence.save(resolution(input: nil, tcfString: "CQ.a", gdprApplies: true, source: .cmp, ts: 5000))
        XCTAssertEqual(storage.writes, 2, "unchanged")
        persistence.save(resolution(input: nil, tcfString: "CQ.b", gdprApplies: true, source: .cmp))
        XCTAssertEqual(storage.writes, 4, "different TC string rewrites both keys")
        persistence.save(resolution(input: nil, tcfString: "CQ.b", gdprApplies: false, source: .cmp))
        XCTAssertEqual(storage.writes, 6)
    }

    func testALaterResolutionWithoutATcStringRemovesTheSideKey() {
        let (persistence, storage, _) = make()
        persistence.save(resolution(input: nil, tcfString: "CQ.a", gdprApplies: true, source: .cmp))
        XCTAssertNotNil(storage.get(keys.consentTcf))
        persistence.save(resolution(input: nil, tcfString: nil, gdprApplies: true, source: .cmp))
        XCTAssertNil(storage.get(keys.consentTcf))
        XCTAssertEqual(storage.removes, 1)
    }

    func testClearRemovesBothKeys() {
        let (persistence, storage, _) = make()
        persistence.save(resolution(tcfString: "TC"))
        persistence.clear()
        XCTAssertNil(storage.get(keys.consent))
        XCTAssertNil(storage.get(keys.consentTcf))
        XCTAssertNil(persistence.load())
    }

    func testAnExpiredTcSideKeyIsDroppedWhileTheMainRecordSurvives() throws {
        let (persistence, storage, _) = make()
        persistence.save(resolution(tcfString: "TC"))
        // Corrupt the side key's expiry.
        storage.set(keys.consentTcf, "{\"v\":1,\"tcfString\":\"TC\",\"ts\":1,\"exp\":\(nowMs - 1)}")

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertNil(loaded.tcfString)
        XCTAssertNotNil(storage.get(keys.consent))
        XCTAssertNil(storage.get(keys.consentTcf), "expired side key removed")
    }

    func testSideKeyEdgeCases() throws {
        // Empty TC string → dropped and removed.
        var storage = InMemoryStore([keys.consent: validMain, keys.consentTcf: "{\"v\":1,\"tcfString\":\"\",\"ts\":1,\"exp\":9999999999999}"])
        XCTAssertNil(try XCTUnwrap(make(storage: storage).0.load()).tcfString)
        XCTAssertNil(storage.get(keys.consentTcf))

        // Wrong version → dropped and removed.
        storage = InMemoryStore([keys.consent: validMain, keys.consentTcf: "{\"v\":2,\"tcfString\":\"TC\",\"ts\":1,\"exp\":9999999999999}"])
        XCTAssertNil(try XCTUnwrap(make(storage: storage).0.load()).tcfString)
        XCTAssertNil(storage.get(keys.consentTcf))

        // Not JSON → no tcfString but the key is LEFT in place (the web read is try/caught without cleanup).
        storage = InMemoryStore([keys.consent: validMain, keys.consentTcf: "garbage"])
        XCTAssertNil(try XCTUnwrap(make(storage: storage).0.load()).tcfString)
        XCTAssertEqual(storage.get(keys.consentTcf), "garbage")

        // Valid → surfaces.
        storage = InMemoryStore([keys.consent: validMain, keys.consentTcf: "{\"v\":1,\"tcfString\":\"CQ.stored\",\"ts\":1,\"exp\":9999999999999}"])
        XCTAssertEqual(try XCTUnwrap(make(storage: storage).0.load()).tcfString, "CQ.stored")
    }

    func testDefaultSourcePersistsAndCustomExpiryApplies() {
        let (persistence, storage, _) = make(expiryDays: 30)
        persistence.save(resolution(signals: .uniform(false), input: nil, source: .default, ts: nowMs))
        XCTAssertEqual(
            storage.get(keys.consent),
            "{\"v\":1,\"signals\":{\"track\":false,\"identify\":false,\"cookieSync\":false},"
                + "\"source\":\"default\",\"ts\":\(nowMs),\"exp\":\(nowMs + 30 * dayMs)}"
        )
        XCTAssertEqual(persistence.load()?.source, .storage)
    }

    func testLoadOfAnAbsentRecordIsNilWithoutWrites() {
        let (persistence, storage, _) = make()
        XCTAssertNil(persistence.load())
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(storage.removes, 0)
    }

    private var validMain: String {
        "{\"v\":1,\"signals\":{\"track\":true,\"identify\":true,\"cookieSync\":true},\"gdprApplies\":true,\"source\":\"cmp\",\"ts\":1699913600000,\"exp\":9999999999999}"
    }
}
