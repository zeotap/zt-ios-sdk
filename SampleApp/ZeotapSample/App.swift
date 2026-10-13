import SwiftUI
import ZeotapSDK

@main
struct ZeotapSampleApp: App {
    @StateObject private var model = SampleModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeScreen().tabItem { Label("Events", systemImage: "bolt") }
                IdentityScreen().tabItem { Label("Identity", systemImage: "person") }
                ConsentScreen().tabItem { Label("Consent", systemImage: "checkmark.shield") }
                SettingsScreen().tabItem { Label("Settings", systemImage: "gear") }
                ReceivedScreen().tabItem { Label("Received", systemImage: "tray") }
            }
            .environmentObject(model)
        }
    }
}

/// Accessibility identifiers double as the shared e2e/mobile/TESTIDS.md contract.
struct HomeScreen: View {
    @EnvironmentObject var model: SampleModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.loaded ? "loaded · anonymousId=\(model.anonymousId)" : "not loaded")
                        .font(.footnote).accessibilityIdentifier("txt-status")
                    Text(model.consentDescription).font(.footnote).accessibilityIdentifier("txt-consent-state")
                    Button("Load SDK") { model.loadSdk() }.accessibilityIdentifier("btn-load")
                    Group {
                        Button("Track") { Zeotap.track("Sample Track", properties: ["count": 1, "source": "sample-app"], completion: model.callback("track")) }.accessibilityIdentifier("btn-track")
                        Button("Track probe") { Zeotap.track("Pre Kill Probe", properties: ["probe": true], completion: model.callback("track")) }.accessibilityIdentifier("btn-track-probe")
                        Button("Screen") { Zeotap.screen("Home", category: "Sample", properties: ["tab": "main"], completion: model.callback("screen")) }.accessibilityIdentifier("btn-screen")
                        Button("Group") { Zeotap.group("acme", traits: ["plan": "enterprise"], completion: model.callback("group")) }.accessibilityIdentifier("btn-group")
                        Button("Alias") { Zeotap.alias("aliased-\(Int(Date().timeIntervalSince1970) % 1000)", completion: model.callback("alias")) }.accessibilityIdentifier("btn-alias")
                        Button("Flush") { Zeotap.flush { model.append("flush done") }; model.append("flush requested") }.accessibilityIdentifier("btn-flush")
                        Button("Reset") { Zeotap.reset(); model.append("reset") }.accessibilityIdentifier("btn-reset")
                    }
                    Divider()
                    Text(model.log.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).accessibilityIdentifier("txt-log")
                }
                .padding()
            }
            .navigationTitle("Zeotap SDK")
        }
    }
}

struct IdentityScreen: View {
    @EnvironmentObject var model: SampleModel
    @State private var email = ""
    @State private var userId = ""

    var body: some View {
        Form {
            TextField("Shopper@Example.com", text: $email).accessibilityIdentifier("input-email")
                .autocapitalization(.none).disableAutocorrection(true)
            TextField("user-42", text: $userId).accessibilityIdentifier("input-user-id")
                .autocapitalization(.none).disableAutocorrection(true)
            Button("Set identities") {
                Zeotap.setUserIdentities(["email": email, "cellno": "91 9999999999", "fpuid": "fp-sample"], completion: model.callback("setUserIdentities"))
            }.accessibilityIdentifier("btn-set-identities")
            Button("Unset identities") { Zeotap.unsetUserIdentities() }.accessibilityIdentifier("btn-unset-identities")
            Button("Identify") { Zeotap.identify(userId: userId.isEmpty ? nil : userId, traits: ["plan": "sample"], completion: model.callback("identify")) }.accessibilityIdentifier("btn-identify")
            // A FIXED value, shared with the Android and RN samples and asserted verbatim by
            // `e2e/helpers/mobile/expectations.ts`. ATT is never authorised on a simulator, so a
            // host-supplied id is the only way to exercise this end to end.
            // Needs `advertisingId=true` at launch — the collection flag gates the setter.
            Button("Set ad id") {
                Zeotap.setAdvertisingId(SampleConfig.sampleAdvertisingId, trackingAuthorized: true)
                model.append("setAdvertisingId ok")
            }.accessibilityIdentifier("btn-set-ad-id")
        }
    }
}

struct ConsentScreen: View {
    @EnvironmentObject var model: SampleModel
    @State private var tcString = "CQAbcSampleTCString"
    @State private var purposes = TcfStubWriter.purposeBits([1, 3, 4, 9])
    @State private var vendors = TcfStubWriter.vendorBits([1469])
    @State private var gdpr = "1"

    var body: some View {
        Form {
            Section(header: Text("Host consent")) {
                Button("Accept all") { Zeotap.setConsent(.parsed(ParsedConsent(analytics: true, marketing: true, advertising: true, functional: true))) }.accessibilityIdentifier("btn-consent-accept")
                Button("Reject all") { Zeotap.setConsent(.parsed(ParsedConsent(analytics: false, marketing: false, advertising: false, functional: false))) }.accessibilityIdentifier("btn-consent-reject")
                Button("TC string") { Zeotap.setConsent(.tcf(tcfString: tcString)) }.accessibilityIdentifier("btn-consent-tcf")
                Button("Consent state") { model.append("consent state: \(Zeotap.getConsentState())") }.accessibilityIdentifier("btn-consent-state")
            }
            Section(header: Text("TCF stub (IABTCF_* in UserDefaults)")) {
                TextField("IABTCF_TCString", text: $tcString).accessibilityIdentifier("input-tc-string")
                TextField("IABTCF_PurposeConsents", text: $purposes).accessibilityIdentifier("input-purposes")
                TextField("IABTCF_VendorConsents", text: $vendors).accessibilityIdentifier("input-vendors")
                TextField("IABTCF_gdprApplies", text: $gdpr).accessibilityIdentifier("input-gdpr-applies")
                Button("Preset: granted 1469") { purposes = TcfStubWriter.purposeBits([1, 3, 4, 9]); vendors = TcfStubWriter.vendorBits([1469]); gdpr = "1" }.accessibilityIdentifier("btn-preset-granted")
                Button("Preset: vendor denied") { vendors = TcfStubWriter.vendorBits([]) }.accessibilityIdentifier("btn-preset-vendor-denied")
                Button("Preset: GDPR n/a") { tcString = ""; purposes = ""; vendors = ""; gdpr = "0" }.accessibilityIdentifier("btn-preset-gdpr-na")
                Button("Write IABTCF_* (CMP answered)") { TcfStubWriter.write(tcString: tcString, purposes: purposes, vendors: vendors, gdprApplies: Int(gdpr)) }.accessibilityIdentifier("btn-tcf-write")
                Button("Write CmpSdkID only (CMP shown)") { TcfStubWriter.cmpOnly() }.accessibilityIdentifier("btn-tcf-cmp-only")
                Button("Clear IABTCF_*") { TcfStubWriter.clear() }.accessibilityIdentifier("btn-tcf-clear")
            }
        }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject var model: SampleModel
    private let cfg = SampleConfig.shared
    @State private var apiHost = SampleConfig.shared.apiHost
    @State private var writeKey = SampleConfig.shared.writeKey
    @State private var consentMode = SampleConfig.shared.consentMode
    @State private var cmp = SampleConfig.shared.cmp
    @State private var lifecycle = SampleConfig.shared.lifecycleEvents
    @State private var adId = SampleConfig.shared.advertisingId
    @State private var autoLoad = SampleConfig.shared.autoLoad

    var body: some View {
        Form {
            TextField("apiHost", text: $apiHost).accessibilityIdentifier("input-api-host").autocapitalization(.none)
            TextField("writeKey", text: $writeKey).accessibilityIdentifier("input-write-key").autocapitalization(.none)
            Picker("consent mode", selection: $consentMode) {
                Text("off (attach only)").tag("off"); Text("opt-in").tag("optin"); Text("opt-out by default").tag("denied")
            }.accessibilityIdentifier("picker-consent-mode")
            Picker("cmp", selection: $cmp) { Text("SDK default").tag(""); Text("auto").tag("auto"); Text("none").tag("none") }.accessibilityIdentifier("picker-cmp")
            Toggle("trackApplicationLifecycleEvents", isOn: $lifecycle).accessibilityIdentifier("toggle-lifecycle")
            Toggle("collectAdvertisingId", isOn: $adId).accessibilityIdentifier("toggle-ad-id")
            Toggle("auto-load on launch", isOn: $autoLoad).accessibilityIdentifier("toggle-auto-load")
            Button("Save") {
                cfg.apiHost = apiHost; cfg.writeKey = writeKey; cfg.consentMode = consentMode; cfg.cmp = cmp
                cfg.lifecycleEvents = lifecycle; cfg.advertisingId = adId; cfg.autoLoad = autoLoad
                model.append("settings saved (takes effect on next launch/Load)")
            }.accessibilityIdentifier("btn-save")
        }
    }
}

struct ReceivedScreen: View {
    @EnvironmentObject var model: SampleModel

    var body: some View {
        List {
            Text("requests: \(model.stub.requestCount) events: \(model.stub.events.count)").accessibilityIdentifier("received.count")
            ForEach(Array(model.stub.events.enumerated()), id: \.element.id) { index, event in
                VStack(alignment: .leading) {
                    Text("\(event.type) \(event.name)").font(.footnote).accessibilityIdentifier("received.event.\(index).type")
                    Text(event.messageId).font(.system(size: 10, design: .monospaced)).accessibilityIdentifier("received.event.\(index).messageId")
                }
            }
        }
    }
}
