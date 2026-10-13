import Foundation
#if canImport(UIKit) && !os(watchOS)
@preconcurrency import UIKit

/// `BackgroundTaskRunner` over `UIApplication.beginBackgroundTask` — buys the background flush its
/// ~30 s of execution after `didEnterBackground`. Apple documents `beginBackgroundTask` /
/// `endBackgroundTask` as safe from any thread, so this is called directly on the core queue
/// (hopping to main asynchronously would race the suspension). Returns `nil` in app extensions,
/// where `UIApplication.shared` is unavailable, and when the system refuses (`.invalid`).
final class UIKitBackgroundTaskRunner: BackgroundTaskRunner {
    init() {}

    func begin(onExpire: @escaping () -> Void) -> BackgroundTaskToken? {
        guard !UIKitAppLifecycle.isAppExtension else { return nil }
        let application = UIApplication.shared
        let lock = NSLock()
        var identifier = UIBackgroundTaskIdentifier.invalid
        var ended = false
        let end: () -> Void = {
            lock.lock()
            let current = identifier
            let alreadyEnded = ended
            ended = true
            identifier = .invalid
            lock.unlock()
            if !alreadyEnded, current != .invalid { application.endBackgroundTask(current) }
        }
        // The expiration handler runs on the main thread. `end` touches only the
        // state behind `lock`, and onExpire (AnalyticsCore) only logs, so neither
        // reaches SDK state unguarded.
        let expiry = QueueHop((onExpire, end))
        let started = application.beginBackgroundTask(withName: "com.zeotap.sdk.flush") {
            expiry.value.0()
            expiry.value.1()
        }
        guard started != .invalid else { return nil }
        lock.lock()
        identifier = started
        let expiredBeforeAssignment = ended
        lock.unlock()
        if expiredBeforeAssignment {
            application.endBackgroundTask(started)
            return nil
        }
        return BackgroundTaskToken(onEnd: end)
    }
}
#endif

/// Platforms without UIKit: no background execution to reserve.
final class NoopBackgroundTaskRunner: BackgroundTaskRunner {
    init() {}
    func begin(onExpire: @escaping () -> Void) -> BackgroundTaskToken? { nil }
}
