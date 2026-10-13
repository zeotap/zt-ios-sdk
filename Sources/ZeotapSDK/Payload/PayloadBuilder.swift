import Foundation

/// An event under construction: top-level `fields` in wire order (with `context` in position) and
/// the mutable `context` pairs that the enqueue step completes (identities and a missing consent
/// are attached at ENQUEUE time, as in the browser SDK).
final class EventDraft {
    let type: String
    let messageId: String
    var fields: [(String, JSONValue)]
    var context: [(String, JSONValue)]

    init(type: String, messageId: String, fields: [(String, JSONValue)], context: [(String, JSONValue)]) {
        self.type = type
        self.messageId = messageId
        self.fields = fields
        self.context = context
    }

    func set(_ key: String, _ value: JSONValue) {
        if let index = fields.firstIndex(where: { $0.0 == key }) { fields[index].1 = value } else { fields.append((key, value)) }
    }

    func has(_ key: String) -> Bool { fields.contains { $0.0 == key } }

    func setContext(_ key: String, _ value: JSONValue) {
        if let index = context.firstIndex(where: { $0.0 == key }) { context[index].1 = value } else { context.append((key, value)) }
    }

    func hasContext(_ key: String) -> Bool { context.contains { $0.0 == key } }

    /// Final wire object with `context` in its original position.
    func materialise() -> JSONValue {
        var out = fields
        if let index = out.firstIndex(where: { $0.0 == "context" }) { out[index].1 = .object(context) }
        return .object(out)
    }
}

/// Builds the base payload exactly like `client.ts` `buildPayload`/`buildContext`:
/// `messageId, type, anonymousId, context, timestamp, sentAt, [userId]`, with
/// `timestamp == sentAt == creation time`. Context: `library{name, version, integration?}` followed
/// by the mobile blocks from `ContextCollector`, then `consent`/`identities` appended by the core.
final class PayloadBuilder {
    private let libraryName: String
    private let libraryVersion: String
    private let integration: IntegrationMeta?
    private let contextCollector: ContextCollector

    init(libraryName: String, libraryVersion: String, integration: IntegrationMeta?, contextCollector: ContextCollector) {
        self.libraryName = libraryName
        self.libraryVersion = libraryVersion
        self.integration = integration
        self.contextCollector = contextCollector
    }

    func base(type: String, messageId: String, anonymousId: String, userId: String?, nowMs: Int64) -> EventDraft {
        let now = Iso8601.format(epochMs: nowMs)
        var fields: [(String, JSONValue)] = [
            ("messageId", .string(messageId)),
            ("type", .string(type)),
            ("anonymousId", .string(anonymousId)),
            ("context", .null), // placeholder, replaced by materialise()
            ("timestamp", .string(now)),
            ("sentAt", .string(now))
        ]
        if let userId { fields.append(("userId", .string(userId))) }

        var library: [(String, JSONValue)] = [("name", .string(libraryName)), ("version", .string(libraryVersion))]
        if let integration {
            library.append(("integration", .object([("name", .string(integration.name)), ("version", .string(integration.version))])))
        }
        var context: [(String, JSONValue)] = [("library", .object(library))]
        context.append(contentsOf: contextCollector.collect())
        return EventDraft(type: type, messageId: messageId, fields: fields, context: context)
    }
}
