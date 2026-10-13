import Foundation
#if canImport(UIKit) && !os(watchOS)
@preconcurrency import UIKit

/// `AppLifecycle` over `UIApplication` notifications: `didEnterBackground` and `willTerminate` →
/// `onBackground` (the web's `pagehide`), `willEnterForeground` → `onForeground`. Inside an app
/// extension (`.appex` bundle) `UIApplication` is unavailable, so `start` is a no-op there.
/// Notifications are delivered on the main thread; the core hops onto its own queue.
final class UIKitAppLifecycle: AppLifecycle {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// `UIApplication.shared` and the app-lifecycle notifications do not exist for extensions.
    static var isAppExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {
        guard !UIKitAppLifecycle.isAppExtension, observers.isEmpty else { return }
        // Both callbacks post straight onto the core queue (AnalyticsCore), so the
        // thread a notification arrives on never touches SDK state.
        let background = QueueHop(onBackground), foreground = QueueHop(onForeground)
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in background.value() },
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in background.value() },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in foreground.value() }
        ]
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
#endif

/// Platforms without UIKit (macOS/Linux test hosts): no foreground/background signal.
final class NoopAppLifecycle: AppLifecycle {
    init() {}
    func start(onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {}
    func stop() {}
}
