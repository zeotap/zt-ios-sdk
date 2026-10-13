import XCTest
@testable import ZeotapSDK

/// Mirror of `sdk/js/src/client.test.ts` — wiring, payload shape, reset/flush and the consent-gating
/// scenarios — run through the real engine over fakes with virtual time.
final class AnalyticsCoreTests: XCTestCase {
    private func harness(_ config: Configuration = CoreHarness.baseConfig(), storage: InMemoryStore = CoreHarness.seededStorage()) -> CoreHarness {
        CoreHarness(config: config, storage: storage)
    }

    // MARK: payload shape

    func testTrackBuildsBasePayloadInWireOrder() {
        let h = harness()
        h.core.track("Button Clicked", properties: ["label": "signup", "count": 2.0], completion: nil)
        h.flushAndSettle()
        let events = h.sentEvents()
        XCTAssertEqual(events.count, 1)
        let p = events[0]
        XCTAssertEqual(p.objectKeys, ["messageId", "type", "anonymousId", "context", "timestamp", "sentAt", "event", "properties"])
        XCTAssertEqual(p["messageId"], .string("00000000-0000-4000-8000-000000000001"))
        XCTAssertEqual(p["anonymousId"], .string(fixedAnon))
        XCTAssertEqual(p["timestamp"], .string("2026-01-15T10:20:30.123Z"))
        XCTAssertEqual(p["sentAt"], p["timestamp"])
        XCTAssertEqual(p["properties"]?["count"], .int(2))
        XCTAssertEqual(p.contextValue?["library"]?["name"], .string("@zeotap/ios-sdk"))
        XCTAssertEqual(p.contextValue?["library"]?["version"], .string("0.0.0-test"))
        XCTAssertEqual(p.contextValue?.objectKeys.first, "library")
        XCTAssertTrue(Set(p.contextValue?.objectKeys ?? []).isSuperset(of: platformContextKeys))
        XCTAssertEqual(h.http.requests.first?.headers["X-Write-Key"], "wk_test")
        XCTAssertEqual(h.http.requests.first?.url.absoluteString, "https://ingest.example/v1/batch")
    }

    func testEmptyEventGroupIdAndNewIdAreSilentNoOps() {
        let h = harness()
        let cb = RecordingCallback()
        h.core.track("", properties: nil, completion: cb.callback)
        h.core.group("", traits: nil, completion: cb.callback)
        h.core.alias("", previousId: nil, completion: cb.callback)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
        XCTAssertTrue(cb.calls.isEmpty)
    }

    func testIdentifyPersistsUserIdAndLaterEventsCarryIt() {
        let h = harness()
        h.core.identify(userId: "user-1", traits: ["plan": "pro"], completion: nil)
        h.core.track("After", properties: nil, completion: nil)
        h.flushAndSettle()
        let events = h.sentEvents()
        XCTAssertEqual(events[0].objectKeys, ["messageId", "type", "anonymousId", "context", "timestamp", "sentAt", "userId", "traits"])
        XCTAssertEqual(events[1].objectKeys, ["messageId", "type", "anonymousId", "context", "timestamp", "sentAt", "userId", "event"])
        XCTAssertEqual(events[1].userIdString, "user-1")
        XCTAssertEqual(h.storage.get("zeotap_user_id"), "user-1")
        XCTAssertEqual(h.core.userId(), "user-1")
    }

    func testScreenGroupAndAliasShapes() {
        let h = harness()
        h.core.screen(category: "Shop", name: "Product", properties: ["sku": "A"], completion: nil)
        h.core.group("acme", traits: ["plan": "enterprise"], completion: nil)
        h.core.alias("new-id", previousId: nil, completion: nil)
        h.flushAndSettle()
        let events = h.sentEvents()
        XCTAssertEqual(Array(events[0].objectKeys.suffix(3)), ["category", "name", "properties"])
        XCTAssertEqual(events[1]["groupId"], .string("acme"))
        XCTAssertEqual(events[2].userIdString, "new-id")
        XCTAssertEqual(events[2]["previousId"], .string(fixedAnon))
    }

    func testIntegrationStampedOnlyWhenBothFieldsPresent() {
        let h = harness(CoreHarness.baseConfig { $0.integration = IntegrationMeta(name: "react-native-sdk", version: "1.2.3") })
        h.core.track("Ev", properties: nil, completion: nil)
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents()[0].contextValue?["library"]?["integration"]?["name"], .string("react-native-sdk"))
        let h2 = harness(CoreHarness.baseConfig { $0.integration = IntegrationMeta(name: "only-name", version: "") })
        h2.core.track("Ev", properties: nil, completion: nil)
        h2.flushAndSettle()
        XCTAssertNil(h2.sentEvents()[0].contextValue?["library"]?["integration"])
    }

    func testConsentAndIdentitiesAttachedAtEnqueue() {
        let h = harness()
        h.core.setConsent(.parsed(ParsedConsent(analytics: true, advertising: false)))
        h.core.setUserIdentities([("fpuid", "fp-1"), ("email", "a@b.com")], hashed: false, completion: nil)
        h.core.track("Ev", properties: nil, completion: nil) // same tick as setUserIdentities
        h.flushAndSettle()
        let ctx = h.sentEvents()[0].contextValue
        XCTAssertEqual(ctx?["consent"]?.objectKeys, ["analytics", "advertising"])
        XCTAssertEqual(ctx?["identities"]?["fpuid"], .string("fp-1"))
        XCTAssertEqual(ctx?["identities"]?["email"]?.objectKeys, ["sha256_lowercase", "sha256_uppercase", "sha1_lowercase", "sha1_uppercase"])
    }

    func testUnsupportedPropertyValueFailsTheCallWithoutCrashing() {
        let h = harness()
        let cb = RecordingCallback()
        h.core.track("Ev", properties: ["bad": NSObject()], completion: cb.callback)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
        XCTAssertEqual(cb.calls.count, 1)
        XCTAssertEqual(cb.calls[0] as? ZeotapError, .invalidProperties(key: "bad"))
    }

    // MARK: queue + flush

    func testAutoFlushesAtFlushAtAndOnTheIntervalTimer() {
        let h = harness(CoreHarness.baseConfig { $0.flushAt = 2; $0.flushInterval = 5000 })
        h.core.track("One", properties: nil, completion: nil)
        h.settle()
        XCTAssertTrue(h.http.requests.isEmpty)
        h.core.track("Two", properties: nil, completion: nil)
        h.settle()
        XCTAssertEqual(h.sentEvents().map(\.eventName), ["One", "Two"])
        h.core.track("Three", properties: nil, completion: nil)
        h.settle()
        XCTAssertEqual(h.http.requests.count, 1)
        h.advance(5000)
        XCTAssertEqual(h.sentEvents().map(\.eventName), ["One", "Two", "Three"])
    }

    func testExhaustedRetriesReleaseTheBatchAndBackOffThenSuccessResets() throws {
        let h = harness()
        h.http.defaultResponse = .success(HTTPResponse(status: 503, body: ""))
        h.core.track("Ev", properties: nil, completion: nil)
        h.flushAndSettle()
        h.advance(500); h.advance(1000); h.advance(2000)
        XCTAssertEqual(h.http.requests.count, 4)
        XCTAssertEqual(try h.eventQueue.count(), 1) // released, not dropped
        h.advance(5000) // timer flush inside the backoff window is suppressed
        XCTAssertEqual(h.http.requests.count, 4)
        h.http.defaultResponse = .success(HTTPResponse(status: 200, body: "{}"))
        h.flushAndSettle() // manual flush forces it
        XCTAssertEqual(h.http.requests.count, 5)
        XCTAssertEqual(try h.eventQueue.count(), 0)
        XCTAssertEqual(Set(h.sentEvents().compactMap { $0["messageId"]?.stringValue }).count, 1) // same messageId every attempt
    }

    func testNonRetryable4xxDropsTheBatchAndNotifiesTheListener() throws {
        let h = harness()
        let listener = RecordingListener()
        h.core.addListener(listener)
        h.http.defaultResponse = .success(HTTPResponse(status: 401, body: "{\"error\":\"write key not found\"}"))
        h.core.track("Ev", properties: nil, completion: nil)
        h.flushAndSettle()
        h.settle()
        XCTAssertEqual(h.http.requests.count, 1)
        XCTAssertEqual(try h.eventQueue.count(), 0)
        XCTAssertEqual(listener.deliveryFailures.first?.status, 401)
        XCTAssertEqual(listener.deliveryFailures.first?.attempts, 1)
    }

    func testPartialFailureSurfacesThroughOnBatchResult() {
        let h = harness()
        let listener = RecordingListener()
        h.core.addListener(listener)
        h.http.defaultResponse = .success(HTTPResponse(status: 200, body: "{\"success\":false,\"received\":0,\"errors\":[\"event 0: missing type\"]}"))
        h.core.track("Ev", properties: nil, completion: nil)
        h.flushAndSettle()
        h.settle()
        XCTAssertEqual(listener.batchResults.count, 1)
        XCTAssertEqual(listener.batchResults[0].success, false)
        XCTAssertEqual(listener.batchResults[0].errors, ["event 0: missing type"])
    }

    func testFlushCompletionRunsAfterTheAttempt() {
        let h = harness()
        h.core.track("Ev", properties: nil, completion: nil)
        var completed = false
        h.core.flush { completed = true }
        h.settle()
        h.settle()
        XCTAssertTrue(completed)
        XCTAssertEqual(h.sentEvents().count, 1)
    }

    func testResetRotatesTheAnonymousIdAndClearsEverything() throws {
        let h = harness(CoreHarness.gated())
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.core.identify(userId: "user-1", traits: nil, completion: nil)
        h.core.setUserIdentities([("fpuid", "fp-1")], hashed: false, completion: nil)
        h.settle()
        let before = h.core.anonymousId()
        h.core.reset()
        h.settle()
        XCTAssertNotEqual(h.core.anonymousId(), before)
        XCTAssertNil(h.core.userId())
        XCTAssertNil(h.storage.get("zeotap_user_identities"))
        XCTAssertNil(h.storage.get("zeotap_consent"))
        XCTAssertFalse(h.core.getConsentState().resolved)
        XCTAssertEqual(try h.eventQueue.count(), 0)
        // The default timer is re-armed: gating resolves with the default after cmpTimeoutMs.
        h.core.track("Later", properties: nil, completion: nil)
        h.advance(10_000)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().map(\.eventName).contains("Later"))
    }

    // MARK: consent gating (client.test.ts "consent gating")

    func testDefaultConfigFlowsImmediatelyEvenWithDenyingConsentAttached() {
        let h = harness()
        h.core.setConsent(.parsed(ParsedConsent(analytics: false)))
        let cb = RecordingCallback()
        h.core.track("Ev", properties: nil, completion: cb.callback)
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents()[0].contextValue?["consent"]?["analytics"], .bool(false))
        XCTAssertEqual(cb.messages, [nil])
    }

    func testRequireBuffersThenReplaysFIFO() {
        let h = harness(CoreHarness.gated())
        h.core.track("First", properties: nil, completion: nil)
        h.core.track("Second", properties: nil, completion: nil)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents().map(\.eventName), ["First", "Second"])
    }

    func testBufferCapDropsTheNewestWithAnError() {
        let h = harness(CoreHarness.gated { $0.maxBufferedEvents = 2 })
        let listener = RecordingListener()
        h.core.addListener(listener)
        let dropped = RecordingCallback()
        h.core.track("A", properties: nil, completion: nil)
        h.core.track("B", properties: nil, completion: nil)
        h.core.track("C", properties: nil, completion: dropped.callback)
        h.settle()
        h.settle()
        XCTAssertEqual(dropped.messages, ["[SDK] Event dropped: pre-consent buffer full"])
        XCTAssertEqual(listener.drops.map(\.reason), [.bufferFull])
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents().map(\.eventName), ["A", "B"])
    }

    func testDefaultTimeoutResolvesGrantedAndReplays() {
        let h = harness(CoreHarness.gated { $0.cmpTimeoutMs = 5000 })
        h.core.track("Ev", properties: nil, completion: nil)
        h.advance(4999)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
        h.advance(1)
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents().map(\.eventName), ["Ev"])
        XCTAssertEqual(h.core.getConsentState().source, .default)
    }

    func testDefaultTimeoutResolvesDeniedAndDropsWithAnError() {
        let h = harness(CoreHarness.gated { $0.default = .denied; $0.cmpTimeoutMs = 5000 })
        let cb = RecordingCallback()
        h.core.track("Ev", properties: nil, completion: cb.callback)
        h.advance(5000)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
        XCTAssertEqual(cb.messages, ["[SDK] Dropped track: no track consent"])
    }

    func testDefaultDeniedAloneActivatesGating() {
        let h = harness(CoreHarness.baseConfig { $0.consent.default = .denied; $0.consent.cmp = .none })
        h.core.track("Ev", properties: nil, completion: nil)
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
    }

    func testUserIdPersistenceIsDeferredUntilIdentifyConsentGranted() {
        let h = harness(CoreHarness.gated())
        h.core.identify(userId: "user-1", traits: nil, completion: nil)
        h.settle()
        XCTAssertNil(h.storage.get("zeotap_user_id"))
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.settle()
        XCTAssertEqual(h.storage.get("zeotap_user_id"), "user-1")
    }

    func testUserIdNeverPersistedWhenIdentifyResolvesDenied() {
        let h = harness(CoreHarness.gated { $0.default = .denied; $0.cmpTimeoutMs = 1000 })
        h.core.identify(userId: "user-1", traits: nil, completion: nil)
        h.advance(1000)
        h.flushAndSettle()
        XCTAssertNil(h.storage.get("zeotap_user_id"))
        XCTAssertTrue(h.sentEvents().isEmpty)
    }

    func testBufferedEventsGainTheUserIdOnceAGrantedIdentifyApplies() {
        let h = harness(CoreHarness.gated())
        h.core.identify(userId: "user-1", traits: nil, completion: nil)
        h.core.track("After Identify", properties: nil, completion: nil)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        let track = h.sentEvents().last
        XCTAssertEqual(track?.eventName, "After Identify")
        XCTAssertEqual(track?.userIdString, "user-1")
    }

    func testResetClearsThePreConsentBuffer() {
        let h = harness(CoreHarness.gated())
        h.core.track("Buffered", properties: nil, completion: nil)
        h.core.reset()
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        XCTAssertTrue(h.sentEvents().isEmpty)
    }

    func testReplayedEventsCarryTheConsentTheyWereReleasedUnder() {
        let h = harness(CoreHarness.gated())
        h.core.track("Held", properties: nil, completion: nil)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        XCTAssertEqual(h.sentEvents()[0].contextValue?["consent"]?["analytics"], .bool(true))
    }

    func testManualDenialDropsTrackAndIdentifyWithTheirOwnMessages() {
        let h = harness(CoreHarness.gated())
        h.core.setConsent(.parsed(ParsedConsent(analytics: false)))
        let a = RecordingCallback()
        let b = RecordingCallback()
        h.core.track("Ev", properties: nil, completion: a.callback)
        h.core.identify(userId: "u1", traits: nil, completion: b.callback)
        h.settle()
        h.settle()
        XCTAssertEqual(a.messages, ["[SDK] Dropped track: no track consent"])
        XCTAssertEqual(b.messages, ["[SDK] Dropped identify: no identify consent"])
    }

    func testManualResolutionPersistsAndHydratesOnReloadAsSourceStorage() {
        let storage = CoreHarness.seededStorage()
        let h = harness(CoreHarness.gated(), storage: storage)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.settle()
        XCTAssertTrue(storage.get("zeotap_consent")?.contains("\"source\":\"manual\"") == true)
        h.core.shutdown()
        let h2 = harness(CoreHarness.gated(), storage: storage)
        XCTAssertEqual(h2.core.getConsentState().source, .storage)
        let writesBefore = storage.writes
        h2.core.track("After", properties: nil, completion: nil)
        h2.flushAndSettle()
        XCTAssertEqual(h2.sentEvents().map(\.eventName), ["After"])
        XCTAssertEqual(storage.writes, writesBefore) // hydration is not re-persisted
    }

    func testPersistFalseWritesNothing() {
        let h = harness(CoreHarness.gated { $0.persist = false })
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.settle()
        XCTAssertNil(h.storage.get("zeotap_consent"))
    }

    func testGetConsentStateReflectsTheResolution() {
        let h = harness(CoreHarness.gated())
        XCTAssertFalse(h.core.getConsentState().resolved)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.settle()
        let state = h.core.getConsentState()
        XCTAssertTrue(state.resolved)
        XCTAssertEqual(state.signals, ConsentSignals(track: true, identify: true, cookieSync: false))
        XCTAssertEqual(state.source, .manual)
    }

    // MARK: identities gating

    func testSetUserIdentitiesBuffersUnderGatingAndAppliesWhenGranted() {
        let h = harness(CoreHarness.gated())
        let cb = RecordingCallback()
        h.core.setUserIdentities([("fpuid", "fp-1")], hashed: false, completion: cb.callback)
        h.settle()
        XCTAssertNil(h.storage.get("zeotap_user_identities"))
        XCTAssertTrue(cb.calls.isEmpty)
        h.core.track("Ev", properties: nil, completion: nil)
        h.core.setConsent(.parsed(ParsedConsent(analytics: true)))
        h.flushAndSettle()
        h.settle()
        XCTAssertEqual(cb.messages, [nil])
        XCTAssertEqual(h.sentEvents()[0].contextValue?["identities"]?["fpuid"], .string("fp-1"))
    }

    func testSetUserIdentitiesDroppedWithAnErrorWhenIdentifyDenied() {
        let h = harness(CoreHarness.gated { $0.default = .denied; $0.cmpTimeoutMs = 1000 })
        let cb = RecordingCallback()
        h.core.setUserIdentities([("fpuid", "fp-1")], hashed: false, completion: cb.callback)
        h.advance(1000)
        h.settle()
        XCTAssertEqual(cb.messages, ["[SDK] Dropped identity update: no identify consent"])
        let late = RecordingCallback()
        h.core.setUserIdentities([("fpuid", "fp-2")], hashed: false, completion: late.callback)
        h.settle()
        h.settle()
        XCTAssertEqual(late.messages, ["[SDK] Identities dropped: no identify consent"])
    }

    func testUnsetUserIdentitiesIsNeverGatedAndResetClearsIdentities() {
        let h = harness(CoreHarness.baseConfig())
        h.core.setUserIdentities([("fpuid", "fp-1"), ("crm", "x")], hashed: false, completion: nil)
        h.settle()
        h.core.unsetUserIdentities(["crm"])
        h.settle()
        XCTAssertEqual(h.storage.get("zeotap_user_identities"), "{\"fpuid\":\"fp-1\"}")
        h.core.reset()
        h.settle()
        XCTAssertNil(h.storage.get("zeotap_user_identities"))
    }

    // MARK: public wrapper

    func testAnalyticsOrdersIdentityKeysCanonically() {
        let ordered = Analytics.ordered(["zzz": "1", "fpuid": "fp", "email": "e", "aaa": "2", "cellno": "9"])
        XCTAssertEqual(ordered.map(\.0), ["email", "cellno", "fpuid", "aaa", "zzz"])
    }
}
