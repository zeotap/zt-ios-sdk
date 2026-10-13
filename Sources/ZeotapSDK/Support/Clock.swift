import Foundation

/// Wall clock in epoch milliseconds. Injectable so tests pin `ts`/`exp`/timestamps.
protocol Clock: Sendable {
    func nowMs() -> Int64
}

struct SystemClock: Clock {
    func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// ISO-8601 UTC with exactly three fractional digits — byte-identical to JavaScript's
/// `Date.prototype.toISOString()` (`2026-01-15T10:20:30.123Z`). Hand-formatted from the
/// Gregorian calendar with an explicit UTC zone so a device on another calendar/zone cannot
/// change the output.
enum Iso8601 {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")! // swiftlint:disable:this force_unwrapping
        return c
    }()

    static func format(epochMs: Int64) -> String {
        let seconds = epochMs.quotientAndRemainder(dividingBy: 1000)
        // Floor division so negative epochs (pre-1970) keep a 0…999 millisecond part.
        let wholeSeconds = seconds.remainder < 0 ? seconds.quotient - 1 : seconds.quotient
        let millis = seconds.remainder < 0 ? seconds.remainder + 1000 : seconds.remainder
        let date = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, Int(millis)
        )
    }
}
