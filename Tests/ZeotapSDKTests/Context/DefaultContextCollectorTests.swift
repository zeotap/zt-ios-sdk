import XCTest
@testable import ZeotapSDK

/// `DefaultContextCollector` on the test host (macOS or Linux — no UIKit, so no `screen` block and
/// no `device.id`). Mirrors the Android `DefaultContextCollectorTest`: contractual key order, value
/// types, advertising-id gating, per-collect network refresh.
final class DefaultContextCollectorTests: XCTestCase {
    private final class FakeAdvertisingIdProvider: AdvertisingIdProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var info: AdvertisingInfo?
        private var callCount = 0

        init(_ info: AdvertisingInfo?) {
            self.info = info
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }

        func set(_ info: AdvertisingInfo?) {
            lock.lock()
            self.info = info
            lock.unlock()
        }

        func current() -> AdvertisingInfo? {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            return info
        }
    }

    private final class FakeNetworkState: NetworkStateProvider {
        var isWifi: Bool
        var isCellular: Bool

        init(wifi: Bool = false, cellular: Bool = false) {
            isWifi = wifi
            isCellular = cellular
        }
    }

    private func collector(
        enabled: Bool = false,
        provider: AdvertisingIdProvider? = nil,
        network: NetworkStateProvider? = nil
    ) -> DefaultContextCollector {
        DefaultContextCollector(collectAdvertisingId: enabled, advertisingIdProvider: provider, networkMonitor: network)
    }

    private func block(_ entries: [(String, JSONValue)], _ name: String) throws -> JSONValue {
        try XCTUnwrap(entries.first { $0.0 == name }?.1, "missing block \(name)")
    }

    #if canImport(UIKit) && os(iOS)
    private let hasScreen = true
    #else
    private let hasScreen = false
    #endif

    // MARK: Order & shape

    func testEntriesComeInTheContractualOrder() {
        let keys = collector().collect().map(\.0)
        if hasScreen {
            XCTAssertEqual(keys, ["app", "device", "os", "network", "screen", "locale", "timezone", "userAgent"])
        } else {
            XCTAssertEqual(keys, ["app", "device", "os", "network", "locale", "timezone", "userAgent"])
        }
    }

    func testKeysAreUnique() {
        let keys = collector().collect().map(\.0)
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testAppBlockHasNameVersionBuildNamespaceAsStrings() throws {
        let app = try block(collector().collect(), "app")
        XCTAssertEqual(app.objectKeys, ["name", "version", "build", "namespace"])
        for (key, value) in app.objectPairs {
            XCTAssertNotNil(value.stringValue, "app.\(key) must be a string")
        }
        let bundle = Bundle.main
        XCTAssertEqual(app["namespace"], .string(bundle.bundleIdentifier ?? ""))
        XCTAssertEqual(app["version"], .string(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
        XCTAssertEqual(app["build"], .string(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))
    }

    func testDeviceBlockWithoutAdvertisingIdWhenDisabledAndProviderUntouched() throws {
        let provider = FakeAdvertisingIdProvider(AdvertisingInfo(id: "abc-123", trackingAuthorized: true))
        let c = collector(enabled: false, provider: provider)
        let device = try block(c.collect(), "device")
        _ = c.collect()

        XCTAssertEqual(device.objectKeys.filter { $0 != "id" }, ["manufacturer", "model", "type"])
        XCTAssertNil(device["advertisingId"])
        XCTAssertNil(device["adTrackingEnabled"])
        XCTAssertEqual(provider.calls, 0)
    }

    func testDeviceStaticFacts() throws {
        let device = try block(collector().collect(), "device")
        #if canImport(Darwin)
        XCTAssertEqual(device["manufacturer"], .string("Apple"))
        #endif
        let model = try XCTUnwrap(device["model"]?.stringValue)
        XCTAssertFalse(model.isEmpty)
        #if os(iOS)
        XCTAssertEqual(device["type"], .string("ios"))
        XCTAssertNotNil(device["id"]?.stringValue)
        #elseif os(macOS)
        XCTAssertEqual(device["type"], .string("macos"))
        XCTAssertNil(device["id"], "identifierForVendor is iOS-only")
        #elseif os(Linux)
        XCTAssertEqual(device["type"], .string("linux"))
        XCTAssertNil(device["id"])
        #endif
    }

    func testDeviceIdIsTheIdentifierForVendorOnlyOnIOS() throws {
        let device = try block(collector().collect(), "device")
        if hasScreen {
            XCTAssertEqual(device.objectKeys.first, "id")
        } else {
            XCTAssertEqual(device.objectKeys.first, "manufacturer")
        }
    }

    // MARK: Advertising id gating

    func testAdvertisingIdHonouredWhenEnabledAndAuthorised() throws {
        let provider = FakeAdvertisingIdProvider(AdvertisingInfo(id: "abc-123", trackingAuthorized: true))
        let c = collector(enabled: true, provider: provider)
        let device = try block(c.collect(), "device")

        XCTAssertEqual(device.objectKeys.filter { $0 != "id" }, ["manufacturer", "model", "type", "advertisingId", "adTrackingEnabled"])
        XCTAssertEqual(device["advertisingId"], .string("abc-123"))
        XCTAssertEqual(device["adTrackingEnabled"], .bool(true))
        XCTAssertEqual(provider.calls, 1)
    }

    func testAdvertisingInfoIsReadOncePerCollect() throws {
        // ATT authorisation changes at runtime, so unlike the static blocks the provider is consulted
        // on every collect().
        let provider = FakeAdvertisingIdProvider(AdvertisingInfo(id: nil, trackingAuthorized: false))
        let c = collector(enabled: true, provider: provider)
        XCTAssertEqual(try block(c.collect(), "device")["adTrackingEnabled"], .bool(false))
        provider.set(AdvertisingInfo(id: "abc-123", trackingAuthorized: true))
        let device = try block(c.collect(), "device")
        XCTAssertEqual(device["advertisingId"], .string("abc-123"))
        XCTAssertEqual(device["adTrackingEnabled"], .bool(true))
        XCTAssertEqual(provider.calls, 2)
    }

    func testUnauthorisedTrackingSuppressesTheIdButReportsTheFlag() throws {
        let provider = FakeAdvertisingIdProvider(AdvertisingInfo(id: "abc-123", trackingAuthorized: false))
        let device = try block(collector(enabled: true, provider: provider).collect(), "device")
        XCTAssertNil(device["advertisingId"])
        XCTAssertEqual(device["adTrackingEnabled"], .bool(false))
        XCTAssertEqual(device.objectKeys.last, "adTrackingEnabled")
    }

    func testZeroUUIDIsSuppressed() throws {
        let device = try block(
            collector(enabled: true, provider: FakeAdvertisingIdProvider(AdvertisingInfo(id: DefaultContextCollector.zeroUUID, trackingAuthorized: true))).collect(),
            "device"
        )
        XCTAssertNil(device["advertisingId"])
        XCTAssertEqual(device["adTrackingEnabled"], .bool(true))
        XCTAssertEqual(DefaultContextCollector.zeroUUID, "00000000-0000-0000-0000-000000000000")
    }

    func testNilIdIsSuppressed() throws {
        let device = try block(collector(enabled: true, provider: FakeAdvertisingIdProvider(AdvertisingInfo(id: nil, trackingAuthorized: true))).collect(), "device")
        XCTAssertNil(device["advertisingId"])
        XCTAssertEqual(device["adTrackingEnabled"], .bool(true))
    }

    func testProviderReturningNilAddsNeitherKey() throws {
        let device = try block(collector(enabled: true, provider: FakeAdvertisingIdProvider(nil)).collect(), "device")
        XCTAssertEqual(device.objectKeys.filter { $0 != "id" }, ["manufacturer", "model", "type"])
    }

    func testEnabledWithoutAProviderAddsNeitherKey() throws {
        let device = try block(collector(enabled: true, provider: nil).collect(), "device")
        XCTAssertNil(device["advertisingId"])
        XCTAssertNil(device["adTrackingEnabled"])
    }

    func testManualAdvertisingIdProviderWorksAsAHostSuppliedSource() throws {
        let manual = ManualAdvertisingIdProvider(AdvertisingInfo(id: "11111111-2222-3333-4444-555555555555", trackingAuthorized: true))
        let c = collector(enabled: true, provider: manual)
        XCTAssertEqual(try block(c.collect(), "device")["advertisingId"], .string("11111111-2222-3333-4444-555555555555"))
        manual.set(nil)
        XCTAssertNil(try block(c.collect(), "device")["advertisingId"])
        XCTAssertNil(try block(c.collect(), "device")["adTrackingEnabled"])
    }

    // MARK: os / screen / locale / timezone / userAgent

    func testOsBlock() throws {
        let os = try block(collector().collect(), "os")
        XCTAssertEqual(os.objectKeys, ["name", "version"])
        #if os(iOS)
        XCTAssertTrue(["iOS", "iPadOS"].contains(os["name"]?.stringValue ?? ""))
        #elseif os(macOS)
        XCTAssertEqual(os["name"], .string("macOS"))
        #elseif os(Linux)
        XCTAssertEqual(os["name"], .string("Linux"))
        #endif
        let version = try XCTUnwrap(os["version"]?.stringValue)
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression), "os.version looks like a dotted version: \(version)")
        #if !os(iOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(version, "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        #endif
    }

    func testScreenBlockOnlyWhereUIKitExists() throws {
        let entries = collector().collect()
        let screen = entries.first { $0.0 == "screen" }?.1
        if hasScreen {
            let screen = try XCTUnwrap(screen)
            XCTAssertEqual(screen.objectKeys, ["width", "height", "density"])
            XCTAssertGreaterThan(try XCTUnwrap(screen["width"]?.intValue), 0)
            XCTAssertGreaterThan(try XCTUnwrap(screen["height"]?.intValue), 0)
            guard case let .double(density)? = screen["density"] else { return XCTFail("density must be a double") }
            XCTAssertGreaterThan(density, 0)
        } else {
            XCTAssertNil(screen, "no UIScreen on this host")
        }
    }

    func testLocaleTimezoneAndUserAgentAreStrings() throws {
        let entries = collector().collect()
        let locale = try XCTUnwrap(try block(entries, "locale").stringValue)
        XCTAssertFalse(locale.isEmpty)
        XCTAssertFalse(locale.contains("_"), "BCP-47 uses hyphens: \(locale)")
        XCTAssertFalse(locale.contains("."), "no POSIX encoding suffix: \(locale)")
        XCTAssertFalse(locale.contains("@"), "no POSIX modifier: \(locale)")

        let timezone = try XCTUnwrap(try block(entries, "timezone").stringValue)
        XCTAssertEqual(timezone, TimeZone.current.identifier)
        XCTAssertFalse(timezone.isEmpty)

        XCTAssertNotNil(try block(entries, "userAgent").stringValue)
    }

    func testUserAgentFormat() throws {
        let entries = collector().collect()
        let userAgent = try XCTUnwrap(try block(entries, "userAgent").stringValue)
        let device = try block(entries, "device")
        let os = try block(entries, "os")
        let model = try XCTUnwrap(device["model"]?.stringValue)
        let osName = try XCTUnwrap(os["name"]?.stringValue)
        let osVersion = try XCTUnwrap(os["version"]?.stringValue)

        XCTAssertEqual(userAgent, "ZeotapSDK/\(SDKVersion.current) (\(model); \(osName) \(osVersion))")
        XCTAssertNotNil(userAgent.range(of: #"^ZeotapSDK/\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)? \(.+; .+ .+\)$"#, options: .regularExpression), userAgent)
    }

    // MARK: network

    func testNetworkBlockDefaultsToOfflineWithoutAMonitor() throws {
        let network = try block(collector(network: nil).collect(), "network")
        XCTAssertEqual(network, .object([("wifi", .bool(false)), ("cellular", .bool(false))]))
    }

    func testNetworkBlockIsRefreshedOnEveryCollect() throws {
        let state = FakeNetworkState(wifi: true, cellular: false)
        let c = collector(network: state)

        XCTAssertEqual(try block(c.collect(), "network"), .object([("wifi", .bool(true)), ("cellular", .bool(false))]))
        state.isWifi = false
        state.isCellular = true
        XCTAssertEqual(try block(c.collect(), "network"), .object([("wifi", .bool(false)), ("cellular", .bool(true))]))
        state.isCellular = false
        XCTAssertEqual(try block(c.collect(), "network"), .object([("wifi", .bool(false)), ("cellular", .bool(false))]))
    }

    func testNetworkBlockAcceptsTheRealMonitorType() throws {
        let monitor = NWPathNetworkMonitor()
        defer { monitor.stop() }
        let network = try block(collector(network: monitor).collect(), "network")
        XCTAssertEqual(network.objectKeys, ["wifi", "cellular"])
        XCTAssertNotNil(network["wifi"]?.boolValue)
        XCTAssertNotNil(network["cellular"]?.boolValue)
    }

    // MARK: Stability

    func testStaticBlocksAreIdenticalAcrossCollects() throws {
        let c = collector()
        let first = c.collect()
        let second = c.collect()
        for name in ["app", "device", "os", "locale", "timezone", "userAgent"] {
            XCTAssertEqual(try block(first, name), try block(second, name), name)
        }
    }

    func testCollectIsSafeFromABackgroundQueueAndOffMainConstruction() throws {
        // The SDK constructs and reads the collector on its serial queue; the UIKit reads must
        // hop to main internally. Off-main construction must neither deadlock nor trap.
        let queue = DispatchQueue(label: "com.zeotap.sdk.test.context")
        let done = expectation(description: "collected off main")
        var keys: [String] = []
        queue.async {
            let c = self.collector()
            keys = c.collect().map(\.0)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(keys.first, "app")
        XCTAssertEqual(keys.last, "userAgent")
    }

    func testPrivacyNoDeviceNameCarrierOrIP() throws {
        let entries = collector(enabled: true, provider: FakeAdvertisingIdProvider(AdvertisingInfo(id: "abc", trackingAuthorized: true))).collect()
        let json = JSONWriter.string(.object(entries)).lowercased()
        for forbidden in ["\"carrier\"", "\"ip\"", "\"idfv\"", "\"devicename\""] {
            XCTAssertFalse(json.contains(forbidden), "context must not contain \(forbidden)")
        }
        let device = try block(entries, "device")
        XCTAssertNil(device["name"], "no device name (privacy default)")
        XCTAssertNil(try block(entries, "network")["carrier"], "no carrier (privacy default)")
    }

    func testOutputSerialisesToValidJSON() throws {
        let provider = FakeAdvertisingIdProvider(AdvertisingInfo(id: "abc-123", trackingAuthorized: true))
        let entries = collector(enabled: true, provider: provider, network: FakeNetworkState(wifi: true)).collect()
        let text = JSONWriter.string(.object(entries))
        let reparsed = try XCTUnwrap(JSONParser.parseOrdered(text))
        XCTAssertEqual(reparsed, .object(entries))
    }
}
