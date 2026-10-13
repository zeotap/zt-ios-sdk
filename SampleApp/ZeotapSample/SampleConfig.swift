import Foundation

/// Sample-app configuration: persisted in UserDefaults and overridable by launch arguments so
/// XCUITest, Maestro and the device-farm harness start the app deterministically:
///
///     -apiHost http://localhost:8090 -writeKey wk_… -consentMode optin -consentDefault denied
///     -cmp auto -autoLoad 1 -lifecycleEvents 1 -flushAt 100 -flushInterval 3600000
///     -ingestStub 1                      (start an in-process ingest stub and point apiHost at it)
///     -tcf.cmpSdkId 300 -tcf.gdprApplies 1 -tcf.tcString CQ… -tcf.purposes 1011… -tcf.vendors 0…1
///     -tcf.writeAfterMs 2000             (simulate a CMP answering late)
final class SampleConfig {
    static let shared = SampleConfig()
    private let defaults = UserDefaults.standard
    private let args = UserDefaults(suiteName: "launch-args")

    private init() {}

    private func string(_ key: String, _ fallback: String) -> String {
        launchArg(key) ?? defaults.string(forKey: "sample.\(key)") ?? fallback
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        if let raw = launchArg(key) { return raw == "1" || raw == "true" }
        return defaults.object(forKey: "sample.\(key)") as? Bool ?? fallback
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        if let raw = launchArg(key), let v = Int(raw) { return v }
        return defaults.object(forKey: "sample.\(key)") as? Int ?? fallback
    }

    /// `-key value` from the process arguments. The LAST occurrence wins, as it does for Android's
    /// intent extras: callers append overrides to a base list (SdkFlowUITests' `launch(extra)`),
    /// and with first-wins every `-consentMode optin` / `-cmp auto` a test appended was silently
    /// ignored — two UI tests asserted opt-in behaviour while running with consent off.
    func launchArg(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: "-\(key)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    var apiHost: String {
        get { string("apiHost", "http://localhost:8090") }
        set { defaults.set(newValue, forKey: "sample.apiHost") }
    }
    var writeKey: String {
        get { string("writeKey", "") }
        set { defaults.set(newValue, forKey: "sample.writeKey") }
    }
    /// off | optin | denied
    var consentMode: String {
        get { string("consentMode", "off") }
        set { defaults.set(newValue, forKey: "sample.consentMode") }
    }
    /// auto | none | "" (SDK default)
    var cmp: String {
        get { string("cmp", "") }
        set { defaults.set(newValue, forKey: "sample.cmp") }
    }
    var cmpTimeoutMs: Int {
        get { int("cmpTimeoutMs", 10_000) }
        set { defaults.set(newValue, forKey: "sample.cmpTimeoutMs") }
    }
    var flushAt: Int {
        get { int("flushAt", 10) }
        set { defaults.set(newValue, forKey: "sample.flushAt") }
    }
    var flushInterval: Int {
        get { int("flushInterval", 5000) }
        set { defaults.set(newValue, forKey: "sample.flushInterval") }
    }
    var lifecycleEvents: Bool {
        get { bool("lifecycleEvents", false) }
        set { defaults.set(newValue, forKey: "sample.lifecycleEvents") }
    }
    /// What `btn-set-ad-id` supplies. Byte-identical to Android's
    /// `SampleConfig.SAMPLE_ADVERTISING_ID`, the RN example's `SAMPLE_ADVERTISING_ID` and
    /// `e2e/helpers/mobile/expectations.ts`, which asserts it reaches the webhook — so one
    /// flow proves the same public API on all three platforms.
    ///
    /// Deliberately not the all-zero UUID: that is what the platforms return for "limit ad
    /// tracking" and the SDK suppresses it, so asserting on it would pass for the wrong reason.
    static let sampleAdvertisingId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    var advertisingId: Bool {
        get { bool("advertisingId", false) }
        set { defaults.set(newValue, forKey: "sample.advertisingId") }
    }
    var autoLoad: Bool {
        get { bool("autoLoad", false) }
        set { defaults.set(newValue, forKey: "sample.autoLoad") }
    }
    var ingestStub: Bool { bool("ingestStub", false) }

    /// `-resetState 1`: start from a fresh install. Everything here — the sample's own settings,
    /// the IABTCF_* keys a CMP stub wrote, the SDK's identity / consent / identities suite and its
    /// durable queue — deliberately survives a relaunch, which is exactly what leaks between UI
    /// tests: a consent decision accepted in one test outranked the CMP in the next, and events a
    /// test left queued were sent by the next test's flush. Must run before the SDK is configured.
    static func resetPersistedState() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults(suiteName: "com.zeotap.sdk")?.removePersistentDomain(forName: "com.zeotap.sdk")
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("com.zeotap.sdk", isDirectory: true))
        }
    }
}
