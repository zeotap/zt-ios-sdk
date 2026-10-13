import Foundation

/// RFC-4122 v4 UUIDs, lowercase hyphenated — same shape as the web SDK's `uuid()`.
protocol IdGenerator: Sendable {
    func uuid() -> String
}

struct SystemIdGenerator: IdGenerator {
    func uuid() -> String { UUID().uuidString.lowercased() }
}
