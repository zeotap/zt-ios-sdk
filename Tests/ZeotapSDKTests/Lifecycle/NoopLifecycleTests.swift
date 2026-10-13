import XCTest
@testable import ZeotapSDK

/// The fallbacks the SDK wires on hosts without UIKit / Network.framework (macOS + Linux test
/// hosts, app extensions): they must never fire a callback and never crash, however they are driven.
final class NoopLifecycleTests: XCTestCase {
    func testNoopAppLifecycleNeverFiresAndToleratesRepeatedStartStop() {
        let lifecycle = NoopAppLifecycle()
        var foreground = 0
        var background = 0

        lifecycle.start(onForeground: { foreground += 1 }, onBackground: { background += 1 })
        lifecycle.start(onForeground: { foreground += 1 }, onBackground: { background += 1 })
        lifecycle.stop()
        lifecycle.stop()
        // Stopping before ever starting is fine too.
        NoopAppLifecycle().stop()

        XCTAssertEqual(foreground, 0)
        XCTAssertEqual(background, 0)
    }

    func testNoopBackgroundTaskRunnerReturnsNoTokenAndNeverExpires() {
        let runner = NoopBackgroundTaskRunner()
        var expired = 0

        let token = runner.begin { expired += 1 }

        XCTAssertNil(token)
        XCTAssertEqual(expired, 0)
    }

    func testBackgroundTaskTokenEndsExactlyOnce() {
        var ended = 0
        let token = BackgroundTaskToken { ended += 1 }

        token.end()
        token.end()
        token.end()

        XCTAssertEqual(ended, 1)
    }

    func testNetworkMonitorFallbackReportsOfflineAndNeverFires() {
        // On Apple platforms this is the real NWPathMonitor wrapper; on Linux the stub. Either way
        // `start` must not fire synchronously (onAvailable is a transition signal, never initial state).
        let monitor = NWPathNetworkMonitor()
        var available = 0

        monitor.start { available += 1 }
        XCTAssertEqual(available, 0)
        monitor.stop()
        monitor.stop()

        #if !canImport(Network)
        XCTAssertFalse(monitor.isWifi)
        XCTAssertFalse(monitor.isCellular)
        #endif
    }

    func testFallbacksSatisfyTheProtocolsTheCoreConsumes() {
        // Compile-time contract: the engine takes these through the protocol types.
        let lifecycle: AppLifecycle = NoopAppLifecycle()
        let tasks: BackgroundTaskRunner = NoopBackgroundTaskRunner()
        let network: NetworkMonitor = NWPathNetworkMonitor()
        let state: NetworkStateProvider = NWPathNetworkMonitor()

        lifecycle.start(onForeground: {}, onBackground: {})
        XCTAssertNil(tasks.begin(onExpire: {}))
        network.start(onAvailable: {})
        _ = state.isWifi
        _ = state.isCellular
        lifecycle.stop()
        network.stop()
    }
}
