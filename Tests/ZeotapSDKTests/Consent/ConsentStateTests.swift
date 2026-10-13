import XCTest
@testable import ZeotapSDK

/// Mirror of the `resolveSignals` / `uniformSignals` half of `sdk/js/src/consent-state.test.ts`,
/// plus the wire (JSON) forms the persisted record and `context.consent` depend on.
final class ConsentStateTests: XCTestCase {
    private func parsed(_ analytics: Bool? = nil, marketing: Bool? = nil, advertising: Bool? = nil, functional: Bool? = nil) -> ConsentInput {
        .parsed(ParsedConsent(analytics: analytics, marketing: marketing, advertising: advertising, functional: functional))
    }

    // MARK: resolveSignals

    func testParsedTrackRequiresAnalyticsNotFalse() {
        XCTAssertTrue(ConsentState.resolveSignals(parsed(true)).track)
        XCTAssertTrue(ConsentState.resolveSignals(parsed()).track, "absent grants")
        XCTAssertTrue(ConsentState.resolveSignals(parsed(advertising: true)).track)
        XCTAssertFalse(ConsentState.resolveSignals(parsed(false)).track)
    }

    func testParsedIdentifyFollowsTrack() {
        XCTAssertTrue(ConsentState.resolveSignals(parsed(true)).identify)
        XCTAssertFalse(ConsentState.resolveSignals(parsed(false)).identify)
        XCTAssertFalse(ConsentState.resolveSignals(parsed(false, advertising: true)).identify)
    }

    func testParsedCookieSyncRequiresAdvertisingOrMarketing() {
        XCTAssertTrue(ConsentState.resolveSignals(parsed(advertising: true)).cookieSync)
        XCTAssertTrue(ConsentState.resolveSignals(parsed(marketing: true)).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(parsed(true)).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(parsed()).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(parsed(functional: true)).cookieSync)
        XCTAssertTrue(ConsentState.resolveSignals(parsed(false, advertising: true)).cookieSync, "cookieSync independent of track")
    }

    func testManualTcfStringGrantsAllSignals() {
        XCTAssertEqual(ConsentState.resolveSignals(.tcf(tcfString: "CO...")), ConsentSignals(track: true, identify: true, cookieSync: true))
    }

    func testEmptyTcfStringDeniesCookieSyncOnly() {
        let signals = ConsentState.resolveSignals(.tcf(tcfString: ""))
        XCTAssertFalse(signals.cookieSync)
        XCTAssertTrue(signals.track)
        XCTAssertTrue(signals.identify)
    }

    func testUsPrivacyGrantsTrackIdentifyAndParsesOptOutOfSale() {
        XCTAssertEqual(ConsentState.resolveSignals(.usPrivacy("1YNN")), ConsentSignals(track: true, identify: true, cookieSync: true))
        XCTAssertFalse(ConsentState.resolveSignals(.usPrivacy("1YYN")).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(.usPrivacy("1yyn")).cookieSync, "case-insensitive")
        XCTAssertTrue(ConsentState.resolveSignals(.usPrivacy("1---")).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(.usPrivacy("")).cookieSync)
        XCTAssertFalse(ConsentState.resolveSignals(.usPrivacy("1Y")).cookieSync, "too short fails safe")
        XCTAssertTrue(ConsentState.resolveSignals(.usPrivacy("1YN")).cookieSync)
        XCTAssertTrue(ConsentState.resolveSignals(.usPrivacy("1YNNN")).cookieSync)
        XCTAssertTrue(ConsentState.resolveSignals(.usPrivacy("1YYN")).track)
    }

    func testUsPrivacyPermitsSyncLooksAtTheThirdUtf16Unit() {
        XCTAssertFalse(ConsentState.usPrivacyPermitsSync(""))
        XCTAssertFalse(ConsentState.usPrivacyPermitsSync("1Y"))
        XCTAssertTrue(ConsentState.usPrivacyPermitsSync("1YN"))
        XCTAssertFalse(ConsentState.usPrivacyPermitsSync("1NY"))
        XCTAssertFalse(ConsentState.usPrivacyPermitsSync("1Ny"))
        XCTAssertTrue(ConsentState.usPrivacyPermitsSync("🙂🙂🙂"), "surrogate pairs count as UTF-16 units, like JS")
    }

    func testConsentPermitsSync() {
        XCTAssertFalse(ConsentState.consentPermitsSync(nil))
        XCTAssertTrue(ConsentState.consentPermitsSync(.tcf(tcfString: "x")))
        XCTAssertFalse(ConsentState.consentPermitsSync(.tcf(tcfString: "")))
        XCTAssertTrue(ConsentState.consentPermitsSync(parsed(marketing: true)))
        XCTAssertFalse(ConsentState.consentPermitsSync(parsed(true, marketing: false, advertising: false)))
    }

    // MARK: uniform

    func testUniformGrantsOrDeniesAllSignals() {
        XCTAssertEqual(ConsentSignals.uniform(true), ConsentSignals(track: true, identify: true, cookieSync: true))
        XCTAssertEqual(ConsentSignals.uniform(false), ConsentSignals(track: false, identify: false, cookieSync: false))
    }

    // MARK: wire forms

    func testToJSONSerialisesEachInputForm() {
        XCTAssertEqual(JSONWriter.string(ConsentState.toJSON(.tcf(tcfString: "CO1"))), "{\"tcfString\":\"CO1\"}")
        XCTAssertEqual(JSONWriter.string(ConsentState.toJSON(.usPrivacy("1YNN"))), "{\"usPrivacy\":\"1YNN\"}")
        XCTAssertEqual(JSONWriter.string(ConsentState.toJSON(parsed(true, advertising: false))), "{\"analytics\":true,\"advertising\":false}")
        XCTAssertEqual(
            JSONWriter.string(ConsentState.toJSON(.parsed(ParsedConsent(marketing: false, functional: true)))),
            "{\"marketing\":false,\"functional\":true}",
            "canonical order"
        )
        XCTAssertEqual(
            JSONWriter.string(ConsentState.toJSON(parsed(nil, marketing: true, advertising: false, functional: true))),
            "{\"marketing\":true,\"advertising\":false,\"functional\":true}"
        )
        XCTAssertEqual(JSONWriter.string(ConsentState.toJSON(parsed())), "{}")
    }

    func testFromJSONIsTheInverseOfToJSON() throws {
        let inputs: [ConsentInput] = [.tcf(tcfString: "CO1"), .tcf(tcfString: ""), .usPrivacy("1YNN"), parsed(true, marketing: false, advertising: true, functional: nil), parsed()]
        for input in inputs {
            XCTAssertEqual(ConsentState.fromJSON(ConsentState.toJSON(input)), input)
        }
        XCTAssertEqual(ConsentState.fromJSON(try XCTUnwrap(JSONParser.parseOrdered("{\"tcfString\":\"a\",\"analytics\":true}"))), .tcf(tcfString: "a"), "tcfString wins")
        XCTAssertEqual(
            ConsentState.fromJSON(try XCTUnwrap(JSONParser.parseOrdered("{\"usPrivacy\":\"1YNN\",\"analytics\":true}"))),
            .usPrivacy("1YNN"),
            "usPrivacy wins over parsed"
        )
        XCTAssertEqual(ConsentState.fromJSON(try XCTUnwrap(JSONParser.parseOrdered("{\"analytics\":\"yes\"}"))), parsed(), "non-boolean members read as absent")
        XCTAssertNil(ConsentState.fromJSON(.string("x")))
        XCTAssertNil(ConsentState.fromJSON(.array([])))
        XCTAssertNil(ConsentState.fromJSON(.null))
    }

    func testSignalsJSONRoundTripKeepsTheContractualOrder() {
        let signals = ConsentSignals(track: true, identify: false, cookieSync: true)
        XCTAssertEqual(JSONWriter.string(ConsentState.signalsToJSON(signals)), "{\"track\":true,\"identify\":false,\"cookieSync\":true}")
        XCTAssertEqual(ConsentState.signalsFromJSON(ConsentState.signalsToJSON(signals)), signals)
        XCTAssertEqual(ConsentState.signalsFromJSON(.object([("track", .bool(true))])), ConsentSignals(track: true, identify: false, cookieSync: false), "missing members deny")
        XCTAssertNil(ConsentState.signalsFromJSON(.string("x")))
    }

    func testConsentSourcePrecedence() {
        XCTAssertLessThan(ConsentSource.default, .storage)
        XCTAssertLessThan(ConsentSource.storage, .cmp)
        XCTAssertLessThan(ConsentSource.cmp, .manual)
        XCTAssertEqual(ConsentSource(rawValue: "default"), .default)
        XCTAssertEqual(ConsentSource.manual.rawValue, "manual")
    }
}
