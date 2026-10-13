import Foundation

/// Carries a value the compiler cannot prove `Sendable` across one GCD hop.
///
/// Dispatch's `async` takes a `@Sendable` closure, and Swift 6 compilers (Xcode 16+) flag every
/// capture of a non-`Sendable` value in one — as warnings in this package's Swift 5 language mode,
/// and as build failures under `-warnings-as-errors`, which is how the `macos` job runs. The
/// values carried here are the SDK's own closures and listener snapshots: each is created on one
/// queue and only ever used on the queue it is handed to, never on two at once. That is the
/// guarantee `Sendable` would prove, made by construction instead — the SDK serialises its state
/// on the core queue and runs callbacks on `callbackQueue`.
///
/// Use it only at a queue boundary, wrap the smallest thing that crosses, and unwrap on the far
/// side. Anything shared between queues needs a lock or a `Sendable` type instead.
struct QueueHop<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
