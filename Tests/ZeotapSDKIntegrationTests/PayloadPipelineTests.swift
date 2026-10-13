import XCTest
@testable import ZeotapSDK

/// Pipeline-level checks that need no fakes from the unit target: the payload builder → draft →
/// writer path produces the browser SDK's byte layout.
final class PayloadPipelineTests: XCTestCase {
    private final class StaticContext: ContextCollector {
        func collect() -> [(String, JSONValue)] {
            [
                ("app", .object([("name", .string("Sample")), ("version", .string("1.0")), ("build", .string("1")), ("namespace", .string("com.example"))])),
                ("device", .object([("manufacturer", .string("Apple")), ("model", .string("iPhone15,2")), ("type", .string("ios"))])),
                ("os", .object([("name", .string("iOS")), ("version", .string("17.4"))])),
                ("locale", .string("en-US")),
                ("timezone", .string("Europe/Berlin"))
            ]
        }
    }

    func testBasePayloadKeyOrderAndTimestamps() {
        let builder = PayloadBuilder(
            libraryName: "@zeotap/ios-sdk",
            libraryVersion: "0.0.0-test",
            integration: IntegrationMeta(name: "react-native-sdk", version: "1.2.3"),
            contextCollector: StaticContext()
        )
        let draft = builder.base(
            type: "track",
            messageId: "00000000-0000-4000-8000-000000000001",
            anonymousId: "11111111-1111-4111-8111-111111111111",
            userId: "user-9",
            nowMs: 1_768_472_430_123
        )
        draft.set("event", .string("Order Completed"))
        draft.set("properties", .object([("total", .double(99.5)), ("quantity", .int(2)), ("gift", .bool(false)), ("coupon", .null)]))
        let json = draft.materialise()
        XCTAssertEqual(json.objectKeys, ["messageId", "type", "anonymousId", "context", "timestamp", "sentAt", "userId", "event", "properties"])
        XCTAssertEqual(json["timestamp"], .string("2026-01-15T10:20:30.123Z"))
        XCTAssertEqual(json["sentAt"], json["timestamp"])
        XCTAssertEqual(json["context"]?.objectKeys, ["library", "app", "device", "os", "locale", "timezone"])
        XCTAssertEqual(json["context"]?["library"]?["integration"]?["name"], .string("react-native-sdk"))
        let text = JSONWriter.string(json)
        // The prefix, not the whole body: what this pins is the KEY ORDER the web SDK
        // fixes (messageId, type, anonymousId, context, …) and the library/integration
        // stamp inside it. Split across lines only for length; the concatenation is
        // one literal.
        let expectedPrefix = "{\"messageId\":\"00000000-0000-4000-8000-000000000001\","
            + "\"type\":\"track\",\"anonymousId\":\"11111111-1111-4111-8111-111111111111\","
            + "\"context\":{\"library\":{\"name\":\"@zeotap/ios-sdk\",\"version\":\"0.0.0-test\","
            + "\"integration\":{\"name\":\"react-native-sdk\",\"version\":\"1.2.3\"}}"
        XCTAssertTrue(text.hasPrefix(expectedPrefix))
        XCTAssertTrue(text.hasSuffix("\"userId\":\"user-9\",\"event\":\"Order Completed\",\"properties\":{\"total\":99.5,\"quantity\":2,\"gift\":false,\"coupon\":null}}"))
    }

    func testContextPlaceholderIsReplacedInPlace() {
        let builder = PayloadBuilder(libraryName: "n", libraryVersion: "v", integration: nil, contextCollector: StaticContext())
        let draft = builder.base(type: "screen", messageId: "m", anonymousId: "a", userId: nil, nowMs: 0)
        draft.setContext("consent", .object([("analytics", .bool(true))]))
        draft.setContext("identities", .object([("fpuid", .string("fp-1"))]))
        let json = draft.materialise()
        XCTAssertEqual(json.objectKeys, ["messageId", "type", "anonymousId", "context", "timestamp", "sentAt"])
        XCTAssertEqual(json["context"]?.objectKeys.suffix(2), ["consent", "identities"])
        XCTAssertEqual(json["timestamp"], .string("1970-01-01T00:00:00.000Z"))
    }
}
