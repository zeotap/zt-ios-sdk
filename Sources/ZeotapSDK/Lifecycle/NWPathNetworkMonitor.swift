import Foundation
#if canImport(Network)
import Network

/// `NetworkMonitor` + `NetworkStateProvider` over `NWPathMonitor` on a private queue. Monitoring
/// begins at construction so the `network` context block is right from the first event;
/// `start(onAvailable:)` only registers the connectivity-regained callback, which fires on
/// `.unsatisfied → .satisfied` transitions (never for the initial path, which merely describes
/// the state the app launched in). `stop()` cancels the monitor for good — it is only called from
/// `shutdown()`. Callbacks arrive on the monitor's queue; the core hops onto its own.
final class NWPathNetworkMonitor: NetworkMonitor, NetworkStateProvider, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.zeotap.sdk.network")
    private let lock = NSLock()
    private var wifi = false
    private var cellular = false
    private var lastStatus: NWPath.Status?
    private var onAvailable: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: monitorQueue)
    }

    var isWifi: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wifi
    }

    var isCellular: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cellular
    }

    func start(onAvailable: @escaping () -> Void) {
        lock.lock()
        self.onAvailable = onAvailable
        lock.unlock()
    }

    func stop() {
        lock.lock()
        onAvailable = nil
        lock.unlock()
        monitor.cancel()
    }

    private func update(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        lock.lock()
        let regained = satisfied && lastStatus != nil && lastStatus != .satisfied
        lastStatus = path.status
        wifi = satisfied && path.usesInterfaceType(.wifi)
        cellular = satisfied && path.usesInterfaceType(.cellular)
        let callback = onAvailable
        lock.unlock()
        if regained { callback?() }
    }
}

#else

/// Platforms without Network.framework (Linux test host): no connectivity signal, `network`
/// reports `{wifi:false, cellular:false}`.
final class NWPathNetworkMonitor: NetworkMonitor, NetworkStateProvider {
    init() {}
    var isWifi: Bool { false }
    var isCellular: Bool { false }
    func start(onAvailable: @escaping () -> Void) {}
    func stop() {}
}

#endif
