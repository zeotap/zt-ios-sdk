# Zeotap iOS SDK

`ZeotapSDK` collects events from iOS apps and sends them to Zeotap. It uses the same event model,
consent model, on-device identity hashing and wire format as the Zeotap browser SDK. Shared
conformance vectors, generated from the browser SDK and run by this repository's tests, prove those
parts match. It also adds what a mobile app needs:
- a durable offline queue
- flush on background
- device and app context
- app-lifecycle events

Swift, **iOS 14+**, no third-party runtime dependencies. MIT licensed. It has three products:

| Product | What it is |
|---|---|
| `ZeotapSDK` | The SDK |
| `ZeotapSDKAdSupport` | Optional IDFA support. It is the only product that links AdSupport / AppTrackingTransparency, so apps that never collect the advertising id ship no tracking frameworks. |
| `ZeotapSDKObjC` | Objective-C wrappers, also used by the React Native bridge |

Full documentation: <https://agentic-docs.zeotap.com/events/ios-sdk>

## Install

**Swift Package Manager.** This repository is the package:

```swift
// Package.swift
.package(url: "https://github.com/zeotap/zeotap-pulse-ios.git", from: "<version>")
```

Or in Xcode, use *File › Add Package Dependencies…* with that URL and pick `ZeotapSDK`. Add
`ZeotapSDKAdSupport` too if you collect the advertising identifier.

**CocoaPods:**

```ruby
pod 'ZeotapSDK', '~> <version>'
pod 'ZeotapSDK/AdSupport'   # optional
```

Releases are the tags of this repository (`v<version>`).

## Quick start

```swift
import ZeotapSDK

try Zeotap.configure(writeKey: "YOUR_WRITE_KEY") { c in
    c.apiHost = "https://events.zeotap.com"
    c.consent.require = true                  // opt-in gating + IABTCF_* auto-detect
    c.trackApplicationLifecycleEvents = true
}

Zeotap.setUserIdentities(["email": "shopper@example.com"])   // hashed on the device
Zeotap.track("Order Completed", properties: ["order_id": "o-1", "total": 99.5])
Zeotap.identify(userId: "user-42", traits: ["plan": "pro"])
Zeotap.reset()                                                // logout
```

`apiHost` is required, because an app has no "same origin". Set it to Zeotap's ingest host or to a
first-party proxy on your own domain. The SDK never shows the App Tracking Transparency prompt; your
app owns it.

## Repository layout

```
Package.swift             products ZeotapSDK / ZeotapSDKAdSupport / ZeotapSDKObjC + test targets
ZeotapSDK.podspec         CocoaPods (subspecs Core / AdSupport / ObjC); version from VERSION
Sources/                  the SDK
Tests/                    unit, conformance and integration suites
  ZeotapSDKTests/Resources/vectors/   golden vectors generated from the browser SDK (read-only here)
SampleApp/                XcodeGen project + SwiftUI app + UI tests
api/ZeotapSDK.api.txt     public-API baseline, checked by scripts/api-check.sh
ci/Dockerfile.linux       Linux Swift image for running the tests without Xcode
conformance/README.md     what the vectors are, and every deliberate platform divergence
```

## Building and testing

On a Mac with Xcode 16:

```bash
swift build -Xswiftc -warnings-as-errors
swift test
pod lib lint ZeotapSDK.podspec --allow-warnings --platforms=ios
```

Without Xcode, the unit and conformance suites run in Linux Swift (CryptoKit is replaced by the
API-identical swift-crypto, and Apple-only frameworks are behind `#if canImport`):

```bash
docker build -t zeotap-swift-test -f ci/Dockerfile.linux ci
docker run --rm -v "$PWD:/work" -w /work zeotap-swift-test scripts/test-linux.sh
docker run --rm -v "$PWD:/work" -w /work zeotap-swift-test scripts/api-check.sh
```

### Conformance

`Tests/ZeotapSDKTests/Resources/vectors/*.vectors.json` are generated from the Zeotap browser SDK,
which is the reference implementation. The test suite runs every vector that applies to iOS. A
vector that fails is a bug. The few places where iOS deliberately differs from the browser are listed,
with reasons, in [`conformance/README.md`](conformance/README.md). Do not edit vectors by hand.

## How this repository is maintained

Zeotap develops the SDK in an internal repository, together with the browser, Android and React
Native SDKs. That keeps one change, reviewed and tested once, in step across all four. On every release
the iOS tree is exported here as one commit tagged `v<version>`. Before that commit is pushed, a
clean checkout of it has passed the test suite above.

So pull requests can't be merged here directly. To report a bug or request a feature, open an issue.
Fixes are made upstream and arrive with the next release.

## License

[MIT](LICENSE) © Zeotap GmbH
