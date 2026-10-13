import Foundation

/// Storage key names — identical to the browser SDK's so a hybrid app's WebView and native layer
/// can share identity/consent (sdk/conformance `storage-keys` vectors). `appVersion`/`appBuild`
/// are mobile-only.
struct Keys: Sendable {
    let anonymousId: String
    let userId: String
    let userIdentities: String
    let consent: String
    let consentTcf: String
    let appVersion: String
    let appBuild: String

    init(namespace: String) {
        anonymousId = "\(namespace)_anonymous_id"
        userId = "\(namespace)_user_id"
        userIdentities = "\(namespace)_user_identities"
        consent = "\(namespace)_consent"
        consentTcf = "\(namespace)_consent_tcf"
        appVersion = "\(namespace)_app_version"
        appBuild = "\(namespace)_app_build"
    }
}
