import XCTest
@testable import ZeotapSDK

/// Mirrors the Android `LifecycleEventsTest`: the opt-in Segment-style application lifecycle
/// events computed from the persisted version/build.
final class LifecycleEventsTests: XCTestCase {
    private let keys = Keys(namespace: "zeotap")
    private var storage = InMemoryStore()

    override func setUp() {
        super.setUp()
        storage = InMemoryStore()
    }

    private func events(version: String = "1.2.3", build: String = "42") -> LifecycleEvents {
        LifecycleEvents(keys: keys, storage: storage, currentVersion: version, currentBuild: build)
    }

    func testFirstLaunchEmitsInstalledThenOpenedAndPersistsVersionAndBuild() {
        let launch = events().onLaunch()

        XCTAssertEqual(launch.map(\.name), ["Application Installed", "Application Opened"])
        XCTAssertEqual(launch[0], LifecycleEvents.Event(name: LifecycleEvents.installed, properties: [
            ("version", .string("1.2.3")),
            ("build", .string("42"))
        ]))
        XCTAssertEqual(launch[1], LifecycleEvents.Event(name: LifecycleEvents.opened, properties: [
            ("from_background", .bool(false)),
            ("version", .string("1.2.3")),
            ("build", .string("42"))
        ]))
        XCTAssertEqual(storage.get("zeotap_app_version"), "1.2.3")
        XCTAssertEqual(storage.get("zeotap_app_build"), "42")
    }

    func testRelaunchOnSameVersionEmitsOnlyOpened() {
        _ = events().onLaunch()
        let launch = events().onLaunch()

        XCTAssertEqual(launch.map(\.name), ["Application Opened"])
        XCTAssertEqual(launch.first?.properties.first?.0, "from_background")
        XCTAssertEqual(launch.first?.properties.first?.1, .bool(false))
    }

    func testVersionChangeEmitsUpdatedWithPreviousValuesThenOpened() {
        _ = events(version: "1.0.0", build: "1").onLaunch()
        let launch = events(version: "1.1.0", build: "2").onLaunch()

        XCTAssertEqual(launch.map(\.name), ["Application Updated", "Application Opened"])
        XCTAssertEqual(launch[0], LifecycleEvents.Event(name: LifecycleEvents.updated, properties: [
            ("version", .string("1.1.0")),
            ("build", .string("2")),
            ("previous_version", .string("1.0.0")),
            ("previous_build", .string("1"))
        ]))
        XCTAssertEqual(storage.get(keys.appVersion), "1.1.0")
        XCTAssertEqual(storage.get(keys.appBuild), "2")
    }

    func testBuildOnlyChangeIsAnUpdateToo() {
        _ = events(version: "1.0.0", build: "1").onLaunch()
        let launch = events(version: "1.0.0", build: "2").onLaunch()

        XCTAssertEqual(launch.first?.name, "Application Updated")
        XCTAssertEqual(JSONValue.object(launch[0].properties)["previous_build"], .string("1"))
        XCTAssertEqual(JSONValue.object(launch[0].properties)["previous_version"], .string("1.0.0"))
    }

    func testPartiallyPersistedStateCountsAsAnUpdateWithNullForTheMissingHalf() {
        // Only one of the two keys survives (a host store that lost a key): not a fresh install.
        storage.set(keys.appVersion, "0.9.0")
        let launch = events(version: "1.0.0", build: "7").onLaunch()

        XCTAssertEqual(launch.map(\.name), ["Application Updated", "Application Opened"])
        XCTAssertEqual(JSONValue.object(launch[0].properties)["previous_version"], .string("0.9.0"))
        XCTAssertEqual(JSONValue.object(launch[0].properties)["previous_build"], .null)
    }

    func testForegroundEmitsOpenedFromBackground() {
        let event = events().onForeground()

        XCTAssertEqual(event.name, "Application Opened")
        XCTAssertEqual(event, LifecycleEvents.Event(name: LifecycleEvents.opened, properties: [
            ("from_background", .bool(true)),
            ("version", .string("1.2.3")),
            ("build", .string("42"))
        ]))
    }

    func testBackgroundEmitsBackgroundedWithNoProperties() {
        let event = events().onBackground()

        XCTAssertEqual(event.name, "Application Backgrounded")
        XCTAssertTrue(event.properties.isEmpty)
    }

    func testForegroundAndBackgroundDoNotTouchStorage() {
        let lifecycle = events()
        _ = lifecycle.onForeground()
        _ = lifecycle.onBackground()

        XCTAssertEqual(storage.writes, 0)
        XCTAssertNil(storage.get(keys.appVersion))
    }

    func testTypicalSessionSequence() {
        let lifecycle = events()
        var names = lifecycle.onLaunch().map(\.name)
        names.append(lifecycle.onBackground().name)
        names.append(lifecycle.onForeground().name)
        names.append(lifecycle.onBackground().name)

        XCTAssertEqual(names, [
            "Application Installed",
            "Application Opened",
            "Application Backgrounded",
            "Application Opened",
            "Application Backgrounded"
        ])
        // onLaunch writes both keys exactly once.
        XCTAssertEqual(storage.writes, 2)
    }

    func testKeysAreNamespaced() {
        let other = Keys(namespace: "acme")
        _ = LifecycleEvents(keys: other, storage: storage, currentVersion: "9", currentBuild: "9").onLaunch()

        XCTAssertEqual(storage.get("acme_app_version"), "9")
        XCTAssertEqual(storage.get("acme_app_build"), "9")
        XCTAssertNil(storage.get("zeotap_app_version"))
    }

    func testEventNamesMatchTheSegmentSpec() {
        XCTAssertEqual(LifecycleEvents.installed, "Application Installed")
        XCTAssertEqual(LifecycleEvents.updated, "Application Updated")
        XCTAssertEqual(LifecycleEvents.opened, "Application Opened")
        XCTAssertEqual(LifecycleEvents.backgrounded, "Application Backgrounded")
    }

    func testEventEqualityIsOrderSensitive() {
        let a = LifecycleEvents.Event(name: "x", properties: [("a", .int(1)), ("b", .int(2))])
        let b = LifecycleEvents.Event(name: "x", properties: [("b", .int(2)), ("a", .int(1))])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, LifecycleEvents.Event(name: "x", properties: [("a", .int(1)), ("b", .int(2))]))
    }
}
