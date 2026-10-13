import XCTest
@testable import ZeotapSDK

/// Smoke tests for the two shipped log sinks. `os.Logger` output cannot be captured from XCTest,
/// so these pin the gating contract (debug off/on, warn/error always) by exercising every path and
/// checking nothing traps — the wording of the messages is the engine's business.
final class LoggingTests: XCTestCase {
    private struct SampleError: Error, CustomStringConvertible {
        var description: String { "sample-error" }
    }

    func testOSLoggerWithDebugDisabledAcceptsEveryLevel() {
        let logger = OSLogger(debugEnabled: false)

        logger.debug("[SDK] debug is gated off")
        logger.warn("[SDK] warn is always emitted")
        logger.error("[SDK] error is always emitted", nil)
        logger.error("[SDK] error with detail", SampleError())
        logger.error("[SDK] error with a ZeotapError", ZeotapError.storage("sqlite: disk full"))
    }

    func testOSLoggerWithDebugEnabledAcceptsEveryLevel() {
        let logger = OSLogger(debugEnabled: true)

        logger.debug("[SDK] Sent 3 events")
        logger.debug("")
        logger.debug("unicode ünïcödé 🎉 and \"quotes\" and %d format specifiers %@")
        logger.warn("[SDK] warn")
        logger.error("[SDK] error", SampleError())
    }

    func testOSLoggerIsUsableThroughTheLoggerProtocolFromAnyThread() {
        let logger: Logger = OSLogger(debugEnabled: true)
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                logger.debug("[SDK] concurrent \(i)")
                logger.warn("[SDK] concurrent warn \(i)")
                logger.error("[SDK] concurrent error \(i)", nil)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    func testNoopLoggerDiscardsEverything() {
        let logger: Logger = NoopLogger()

        logger.debug("dropped")
        logger.warn("dropped")
        logger.error("dropped", SampleError())
        logger.error("dropped", nil)
    }

    func testNoopLoggerCanStandInForTheDefaultSink() {
        // The engine holds its sink as `Logger`; both concrete types must be interchangeable.
        let sinks: [Logger] = [NoopLogger(), OSLogger(debugEnabled: false), OSLogger(debugEnabled: true)]
        for sink in sinks {
            sink.debug("x")
            sink.warn("y")
            sink.error("z", nil)
        }
        XCTAssertEqual(sinks.count, 3)
    }
}
