import XCTest
@testable import ZeotapSDK

/// sdk/conformance/vectors/storage-keys.vectors.json — the `{ns}_*` key names shared with the
/// browser SDK (a hybrid app's WebView and native layer read the same identity/consent records).
final class StorageKeysConformanceTests: XCTestCase {
    func testStorageKeyVectors() {
        let cases = VectorLoader.cases("storage-keys")
        XCTAssertFalse(cases.isEmpty, "no storage-keys vectors loaded")
        for testCase in cases {
            XCTContext.runActivity(named: "storage-keys/\(testCase.id)") { _ in
                let namespace = testCase.input["namespace"]?.stringValue ?? ""
                let keys = Keys(namespace: namespace)
                let actual = JSONValue.object([
                    ("anonymousId", .string(keys.anonymousId)),
                    ("userId", .string(keys.userId)),
                    ("userIdentities", .string(keys.userIdentities)),
                    ("consent", .string(keys.consent)),
                    ("consentTcf", .string(keys.consentTcf))
                ])
                assertJSONEquivalent(actual, testCase.expected, "storage-keys/\(testCase.id)")
                // Mobile-only keys follow the same `{ns}_` convention.
                XCTAssertEqual(keys.appVersion, "\(namespace)_app_version", "storage-keys/\(testCase.id): appVersion")
                XCTAssertEqual(keys.appBuild, "\(namespace)_app_build", "storage-keys/\(testCase.id): appBuild")
            }
        }
    }
}
