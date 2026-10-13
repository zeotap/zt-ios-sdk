import Foundation
import XCTest
@testable import ZeotapSDK

/// Loads `sdk/conformance/vectors/<family>.vectors.json` (committed copy under
/// `Tests/ZeotapSDKTests/Resources/vectors/`, kept in sync by `scripts/sync-vectors.sh`).
///
/// The `#filePath`-relative location is tried first: SwiftPM's generated `Bundle.module` traps
/// (`fatalError`) when the resource bundle is missing, which happens on some Linux toolchains for
/// copied directories, so it is only consulted when the source tree is not available.
/// Cases tagged with a `platforms` array that lacks `"ios"` are skipped.
enum VectorLoader {
    typealias Case = (id: String, input: JSONValue, expected: JSONValue, raw: JSONValue)

    static func cases(_ family: String) -> [Case] {
        guard let document = document(family), let cases = document["cases"]?.arrayValue else {
            XCTFail("could not load conformance vectors for family \(family)")
            return []
        }
        return cases.compactMap { raw -> Case? in
            guard let id = raw["id"]?.stringValue else { return nil }
            if let platforms = raw["platforms"]?.arrayValue, !platforms.contains(.string("ios")) { return nil }
            return (id: id, input: raw["input"] ?? .null, expected: raw["expected"] ?? .null, raw: raw)
        }
    }

    /// The whole vectors document (`family`, `version`, `notes`, `cases`, …).
    static func document(_ family: String) -> JSONValue? {
        guard let url = url(for: family), let data = try? Data(contentsOf: url) else { return nil }
        return JSONParser.parseOrdered(String(decoding: data, as: UTF8.self))
    }

    static func url(for family: String) -> URL? {
        let fileName = "\(family).vectors.json"
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conformance/
            .deletingLastPathComponent() // ZeotapSDKTests/
            .appendingPathComponent("Resources/vectors")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: sourceRelative.path) { return sourceRelative }
        return Bundle.module.url(forResource: "\(family).vectors", withExtension: "json", subdirectory: "vectors")
    }
}
