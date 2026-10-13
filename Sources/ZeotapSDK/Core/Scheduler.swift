import Foundation

/// A cancellable timer handle.
final class ScheduledTask {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// Timers + posting for the SDK's serial queue. Every block runs ON `queue`, so timers are
/// serialised with API calls. Tests substitute a fake with virtual time.
protocol Scheduler: AnyObject {
    var queue: DispatchQueue { get }
    func async(_ block: @escaping () -> Void)
    func schedule(after ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask
    func repeating(every ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask
}

/// `DispatchSourceTimer`-backed scheduler on the core queue.
final class DispatchScheduler: Scheduler {
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func async(_ block: @escaping () -> Void) {
        let hop = QueueHop(block)
        queue.async { hop.value() }
    }

    func schedule(after ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(ms)))
        timer.setEventHandler {
            timer.cancel()
            block()
        }
        timer.resume()
        return ScheduledTask { timer.cancel() }
    }

    func repeating(every ms: Int64, _ block: @escaping () -> Void) -> ScheduledTask {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(ms)), repeating: .milliseconds(Int(ms)))
        timer.setEventHandler(handler: block)
        timer.resume()
        return ScheduledTask { timer.cancel() }
    }
}
