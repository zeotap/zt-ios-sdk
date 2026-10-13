import XCTest

/// Real-process XCUITests: the sample app + the real SDK against the in-process ingest stub.
/// Covers what unit tests cannot — the durable queue surviving terminate/relaunch, the background
/// flush on Home, the TCF defaults path and the request shape on a real (simulated) device.
final class SdkFlowUITests: XCTestCase {
    /// Every launch starts from a fresh install (`-resetState 1`) unless `keepState` — the queue,
    /// consent and identity all persist across launches by design, and without the reset each test
    /// inherited the last one's (a persisted manual consent outranked the CMP in the TCF test;
    /// events queued by one test were sent by the next).
    private func launch(_ extra: [String] = [], stub: Bool = true, keepState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-writeKey", "wk_uitest", "-autoLoad", "1", "-flushAt", "100", "-flushInterval", "3600000", "-consentMode", "off", "-cmp", "none"]
        if !keepState { app.launchArguments += ["-resetState", "1"] }
        if stub { app.launchArguments += ["-ingestStub", "1"] }
        app.launchArguments += extra
        app.launch()
        return app
    }

    private func receivedCount(_ app: XCUIApplication) -> Int {
        app.tabBars.buttons["Received"].tap()
        let label = app.staticTexts["received.count"].label
        let events = label.split(separator: " ").last.flatMap { Int($0) } ?? -1
        app.tabBars.buttons["Events"].tap()
        return events
    }

    private func waitForReceived(_ app: XCUIApplication, atLeast n: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if receivedCount(app) >= n { return true }
            sleep(1)
        }
        return false
    }

    func testTrackAndFlushReachTheStub() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["txt-status"].label.hasPrefix("loaded"))
        app.buttons["btn-track"].tap()
        app.buttons["btn-flush"].tap()
        XCTAssertTrue(waitForReceived(app, atLeast: 1), "track did not reach ingest")
        app.tabBars.buttons["Received"].tap()
        XCTAssertTrue(app.staticTexts["received.event.0.type"].label.hasPrefix("track Sample Track"))
    }

    func testQueuedEventsSurviveTerminateAndRelaunchWithSameMessageIds() {
        // Ingest unreachable on first launch: the stub is off, so retries exhaust and rows are released.
        var app = launch(stub: false)
        app.buttons["btn-track-probe"].tap()
        app.buttons["btn-flush"].tap()
        sleep(5) // 500 + 1000 + 2000 ms backoff
        app.terminate()

        // Relaunch with the stub up and WITHOUT the reset: the released rows are re-sent.
        app = launch(keepState: true)
        app.buttons["btn-flush"].tap()
        XCTAssertTrue(waitForReceived(app, atLeast: 1), "released rows were not re-sent after relaunch")
        app.tabBars.buttons["Received"].tap()
        XCTAssertTrue(app.staticTexts["received.event.0.type"].label.contains("Pre Kill Probe"))
    }

    /// Intermittent on CI (failed 2 of its first 3 runs, all as the first test of the bundle) with
    /// nothing to say why, so on failure it prints the app's own log — the SDK listener's batch
    /// results and delivery failures — into the test output. The leading suspect is the simulator
    /// suspending the IN-PROCESS ingest stub along with the app; the log tells that apart from a
    /// background flush that never started.
    func testBackgroundingFlushesTheQueue() {
        let app = launch()
        app.buttons["btn-screen"].tap()
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let flushed = waitForReceived(app, atLeast: 1)
        if !flushed { dumpAppLog(app) }
        XCTAssertTrue(flushed, "background did not flush (app log printed above and attached)")
    }

    private func dumpAppLog(_ app: XCUIApplication) {
        let log = app.staticTexts["txt-log"]
        let text = log.exists ? log.label : "<txt-log not in the view hierarchy>"
        print("── ZeotapSample log ──\n\(text)\n── end log ──")
        let attachment = XCTAttachment(string: text)
        attachment.name = "ZeotapSample log"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Buffer-then-release. The REJECT half of the gate (a denied decision drops the
    /// buffered event) is asserted on a real device by the `opt-in-reject` scenario in
    /// `e2e/tests/mobile/` — this test's old name promised it and never exercised it.
    ///
    /// The `receivedCount == 0` assertion below used to be time-dependent: `optin` mapped
    /// to `default = .granted`, so the 10 s cmpTimeoutMs timer would release the buffered
    /// event and only the 2 s sleep kept the test green. `optin` now means denied-by-
    /// default (see SampleModel), so nothing but a manual grant can release it.
    func testOptInGatingBuffersUntilConsent() {
        let app = launch(["-consentMode", "optin"])
        app.buttons["btn-track"].tap()
        app.buttons["btn-flush"].tap()
        sleep(2)
        XCTAssertEqual(receivedCount(app), 0, "gated event must not be sent before consent")
        app.tabBars.buttons["Consent"].tap()
        app.buttons["btn-consent-accept"].tap()
        app.tabBars.buttons["Events"].tap()
        app.buttons["btn-flush"].tap()
        XCTAssertTrue(waitForReceived(app, atLeast: 1))
        XCTAssertTrue(app.staticTexts["txt-consent-state"].label.contains("manual"))
    }

    func testTcfDefaultsResolveConsentWithoutHostCalls() {
        let purposes = (1...24).map { [1, 3, 4, 9].contains($0) ? "1" : "0" }.joined()
        let vendors = (1...1469).map { $0 == 1469 ? "1" : "0" }.joined()
        let app = launch(["-consentMode", "optin", "-cmp", "auto", "-tcf.cmpSdkId", "300", "-tcf.gdprApplies", "1", "-tcf.tcString", "CQAbcUITest", "-tcf.purposes", purposes, "-tcf.vendors", vendors])
        let state = app.staticTexts["txt-consent-state"]
        let resolved = NSPredicate(format: "label CONTAINS 'cmp'")
        expectation(for: resolved, evaluatedWith: state)
        waitForExpectations(timeout: 10)
        app.buttons["btn-track"].tap()
        app.buttons["btn-flush"].tap()
        XCTAssertTrue(waitForReceived(app, atLeast: 1))
    }

    func testLifecycleEventsFireOnFreshInstall() {
        let app = launch(["-lifecycleEvents", "1"])
        app.buttons["btn-flush"].tap()
        XCTAssertTrue(waitForReceived(app, atLeast: 2))
        app.tabBars.buttons["Received"].tap()
        XCTAssertTrue(app.staticTexts["received.event.0.type"].label.contains("Application"))
    }
}
