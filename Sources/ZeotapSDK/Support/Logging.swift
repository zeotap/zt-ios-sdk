import Foundation
#if canImport(os)
import os
#endif

/// Default log sink: `os.Logger` (subsystem `com.zeotap.sdk`, category `sdk`) on Apple platforms,
/// `print` elsewhere. `debug` is gated on `debugEnabled` (the browser SDK's `debug: true`);
/// warnings and errors are always emitted, exactly like the web's `console.warn`/`console.error`.
/// Messages are marked public in the unified log — the SDK never puts identity values in them.
final class OSLogger: Logger, @unchecked Sendable {
    private let debugEnabled: Bool
    #if canImport(os)
    private let log = os.Logger(subsystem: "com.zeotap.sdk", category: "sdk")
    #endif

    init(debugEnabled: Bool) {
        self.debugEnabled = debugEnabled
    }

    func debug(_ message: String) {
        guard debugEnabled else { return }
        #if canImport(os)
        log.debug("\(message, privacy: .public)")
        #else
        print(message)
        #endif
    }

    func warn(_ message: String) {
        #if canImport(os)
        log.warning("\(message, privacy: .public)")
        #else
        print(message)
        #endif
    }

    func error(_ message: String, _ error: Error?) {
        let detail = error.map { " \(String(describing: $0))" } ?? ""
        #if canImport(os)
        log.error("\(message, privacy: .public)\(detail, privacy: .public)")
        #else
        print(message + detail)
        #endif
    }
}

/// Discards everything — tests, and hosts that opt out of SDK logging entirely.
final class NoopLogger: Logger {
    init() {}
    func debug(_ message: String) {}
    func warn(_ message: String) {}
    func error(_ message: String, _ error: Error?) {}
}
