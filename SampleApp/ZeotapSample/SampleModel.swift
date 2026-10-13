import Foundation
import ZeotapSDK
import ZeotapSDKAdSupport

/// Owns the SDK instance, the in-memory log the UI renders and the optional ingest stub.
final class SampleModel: ObservableObject, SdkListener {
    @Published var log: [String] = []
    @Published var loaded = false
    @Published var anonymousId = ""
    @Published var consentDescription = "consent: unresolved"
    let stub = IngestStubServer()
    private var refreshTimer: Timer?

    init() {
        let config = SampleConfig.shared
        if config.launchArg("resetState") == "1" {
            SampleConfig.resetPersistedState()
            append("state reset (fresh install)")
        }
        if config.ingestStub, let port = try? stub.start() {
            config.apiHost = "http://127.0.0.1:\(port)"
            append("ingest stub on port \(port)")
        }
        TcfStubWriter.applyLaunchArguments()
        if config.autoLoad { loadSdk() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func append(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.log.insert("\(stamp)  \(line)", at: 0)
            if self.log.count > 200 { self.log.removeLast() }
        }
    }

    /// Idempotent: `Zeotap.configure` returns the existing instance after the first call.
    func loadSdk() {
        let cfg = SampleConfig.shared
        guard !cfg.writeKey.isEmpty else {
            append("writeKey missing — set it in Settings")
            return
        }
        do {
            let sdk = try Zeotap.configure(writeKey: cfg.writeKey) { c in
                c.apiHost = cfg.apiHost
                c.debug = true
                c.flushAt = cfg.flushAt
                c.flushInterval = cfg.flushInterval
                // `optin` means DENIED-by-default, not granted-by-default. With
                // `default = .granted` the gate is active but the cmpTimeoutMs timer
                // resolves to GRANTED, so a pre-consent event is buffered and then
                // RELEASED ~10 s later — opt-OUT behaviour under an opt-in label. That
                // made the gating assertion in ZeotapSampleUITests a race it happened to
                // win at 2 s, and it diverged from the Android sample, which takes
                // `require` and `default` as two independent launch arguments and is
                // driven with `consentDefault=denied` by the same Maestro flow
                // (e2e/mobile/flows/opt-in-reject.yaml). `denied` is kept as an explicit
                // synonym so existing launch arguments keep working.
                c.consent.require = cfg.consentMode != "off"
                c.consent.default = cfg.consentMode == "off" ? .granted : .denied
                c.consent.cmpTimeoutMs = cfg.cmpTimeoutMs
                switch cfg.cmp {
                case "auto": c.consent.cmp = .auto
                case "none": c.consent.cmp = .none
                default: break
                }
                c.trackApplicationLifecycleEvents = cfg.lifecycleEvents
                c.collectAdvertisingId = cfg.advertisingId
                if cfg.advertisingId { c.advertisingIdProvider = ATTAdvertisingIdProvider() }
            }
            sdk.addListener(self)
            append("SDK loaded apiHost=\(cfg.apiHost) mode=\(cfg.consentMode) anonymousId=\(sdk.anonymousId)")
            refresh()
        } catch {
            append("configure failed: \(error.localizedDescription)")
        }
    }

    func callback(_ method: String) -> Callback {
        { [weak self] error in
            self?.append(error == nil ? "\(method) ok" : "\(method) dropped: \(error?.localizedDescription ?? "")")
        }
    }

    func refresh() {
        loaded = Zeotap.isConfigured
        anonymousId = Zeotap.shared?.anonymousId ?? ""
        let state = Zeotap.getConsentState()
        consentDescription = state.resolved
            ? "consent: \(state.source?.rawValue ?? "?") track=\(state.signals?.track ?? false) identify=\(state.signals?.identify ?? false)"
            : "consent: unresolved"
    }

    // MARK: SdkListener

    func onBatchResult(_ result: BatchResult) {
        append("batch \(result.status) success=\(result.success) received=\(result.received)/\(result.sent) errors=\(result.errors)")
    }

    func onDeliveryFailure(status: Int?, attempts: Int, error: Error?) {
        append("delivery failure status=\(status.map(String.init) ?? "none") attempts=\(attempts) \(error?.localizedDescription ?? "")")
    }

    func onEventDropped(type: String, reason: DropReason, message: String) {
        append("dropped \(type) (\(reason.rawValue)): \(message)")
    }

    func onError(_ error: Error) {
        append("error: \(error.localizedDescription)")
    }
}

/// Simulates a CMP: writes the IAB TCF-for-Apps keys the SDK observes into `UserDefaults.standard`.
enum TcfStubWriter {
    static func purposeBits(_ granted: Set<Int>) -> String { (1...24).map { granted.contains($0) ? "1" : "0" }.joined() }

    static func vendorBits(_ granted: Set<Int>) -> String {
        let length = max(1469, granted.max() ?? 0)
        return (1...length).map { granted.contains($0) ? "1" : "0" }.joined()
    }

    static func write(tcString: String?, purposes: String?, vendors: String?, gdprApplies: Int?, cmpSdkId: Int = 300) {
        let d = UserDefaults.standard
        d.set(cmpSdkId, forKey: "IABTCF_CmpSdkID")
        if let gdprApplies { d.set(gdprApplies, forKey: "IABTCF_gdprApplies") } else { d.removeObject(forKey: "IABTCF_gdprApplies") }
        if let tcString, !tcString.isEmpty { d.set(tcString, forKey: "IABTCF_TCString") } else { d.removeObject(forKey: "IABTCF_TCString") }
        if let purposes, !purposes.isEmpty { d.set(purposes, forKey: "IABTCF_PurposeConsents") } else { d.removeObject(forKey: "IABTCF_PurposeConsents") }
        if let vendors, !vendors.isEmpty { d.set(vendors, forKey: "IABTCF_VendorConsents") } else { d.removeObject(forKey: "IABTCF_VendorConsents") }
    }

    static func cmpOnly() {
        clear()
        UserDefaults.standard.set(300, forKey: "IABTCF_CmpSdkID")
    }

    static func clear() {
        for key in ["IABTCF_CmpSdkID", "IABTCF_gdprApplies", "IABTCF_TCString", "IABTCF_PurposeConsents", "IABTCF_VendorConsents"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// `-tcf.*` launch arguments, optionally applied after `-tcf.writeAfterMs`.
    static func applyLaunchArguments() {
        let cfg = SampleConfig.shared
        guard cfg.launchArg("tcf.cmpSdkId") != nil || cfg.launchArg("tcf.gdprApplies") != nil || cfg.launchArg("tcf.tcString") != nil else { return }
        clear()
        let apply = {
            write(
                tcString: cfg.launchArg("tcf.tcString"),
                purposes: cfg.launchArg("tcf.purposes"),
                vendors: cfg.launchArg("tcf.vendors"),
                gdprApplies: cfg.launchArg("tcf.gdprApplies").flatMap(Int.init),
                cmpSdkId: cfg.launchArg("tcf.cmpSdkId").flatMap(Int.init) ?? 300
            )
        }
        if let delay = cfg.launchArg("tcf.writeAfterMs").flatMap(Int.init), delay > 0 {
            UserDefaults.standard.set(300, forKey: "IABTCF_CmpSdkID") // CMP present, no answer yet
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: apply)
        } else {
            apply()
        }
    }
}
