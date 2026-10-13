// swift-tools-version:5.9
import PackageDescription

// SignalSmith iOS SDK (increment 243).
//
// Products:
//  - ZeotapSDK           the SDK (Foundation, SQLite3, URLSession, CryptoKit, Network; UIKit behind #if canImport)
//  - ZeotapSDKAdSupport  optional IDFA/ATT provider — the ONLY target that links AdSupport/AppTrackingTransparency,
//                        so integrators who never collect the advertising id ship no tracking frameworks
//  - ZeotapSDKObjC       @objc wrappers for Objective-C hosts and the React Native bridge
//
// Test hosts: macOS is declared so `swift test` runs the unit + conformance suites on a Mac
// without a simulator; Linux is supported for the same reason (CI containers, machines with
// Command Line Tools but no Xcode — XCTest ships only with Xcode). On Linux, CryptoKit is
// replaced by swift-crypto (API-identical `Crypto`) and SQLite comes from the system library
// via the CSQLite module; everything Apple-only (UIKit, Network, os.Logger, SQLite3) is
// guarded with `#if canImport`. Production support is iOS 14+.
let package = Package(
    name: "ZeotapSDK",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "ZeotapSDK", targets: ["ZeotapSDK"]),
        .library(name: "ZeotapSDKAdSupport", targets: ["ZeotapSDKAdSupport"]),
        .library(name: "ZeotapSDKObjC", targets: ["ZeotapSDKObjC"]),
    ],
    dependencies: [
        // Linux test host only (see the platform condition below). Apple platforms use CryptoKit,
        // so this range constrains nothing a customer consumes — only what `make sdk-ios-test`
        // compiles against.
        //
        // Capped BELOW 4.0.0 on purpose: swift-crypto 4.x declares swift-tools-version 6.0, and
        // `ci/Dockerfile.linux` is pinned to Swift 5.10 because 6.x stalls in swift-corelibs-xctest.
        // With the old `..<"5.0.0"` the two pins contradicted each other and only `Package.resolved`
        // stood between them — so the first re-resolution (a cold cache, a stale checkout, anyone
        // running `swift package update`) broke the build with an error about a *transitive*
        // package's tools version, which points nowhere near the cause. Raise this only together
        // with the image.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "ZeotapSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/ZeotapSDK",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency=complete")]
        ),
        .target(
            name: "ZeotapSDKAdSupport",
            dependencies: ["ZeotapSDK"],
            path: "Sources/ZeotapSDKAdSupport",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "ZeotapSDKObjC",
            dependencies: ["ZeotapSDK"],
            path: "Sources/ZeotapSDKObjC"
        ),
        .testTarget(
            name: "ZeotapSDKTests",
            dependencies: ["ZeotapSDK"],
            path: "Tests/ZeotapSDKTests",
            resources: [.copy("Resources/vectors")]
        ),
        .testTarget(
            name: "ZeotapSDKIntegrationTests",
            dependencies: ["ZeotapSDK"],
            path: "Tests/ZeotapSDKIntegrationTests"
        ),
    ]
)
