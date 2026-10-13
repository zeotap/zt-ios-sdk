import Foundation

/// Process-level foreground/background signal (the web SDK's `visibilitychange`/`pagehide`).
/// Implemented over `UIApplication` notifications where UIKit exists; a no-op elsewhere (macOS
/// test host, app extensions).
protocol AppLifecycle: AnyObject {
    /// Callbacks arrive on an arbitrary thread; the core hops onto its serial queue.
    func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void)
    func stop()
}

/// Background-time reservation around the background flush (`beginBackgroundTask`). The
/// returned token must be ended exactly once.
protocol BackgroundTaskRunner: AnyObject {
    func begin(onExpire: @escaping () -> Void) -> BackgroundTaskToken?
}

final class BackgroundTaskToken {
    private var onEnd: (() -> Void)?

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    func end() {
        onEnd?()
        onEnd = nil
    }
}

/// Connectivity-regained signal; the SDK flushes and resets its backoff on it.
protocol NetworkMonitor: AnyObject {
    func start(onAvailable: @escaping () -> Void)
    func stop()
}
