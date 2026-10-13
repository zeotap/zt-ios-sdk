import Foundation

/// Computes the opt-in application lifecycle events (Segment-compatible names and properties)
/// from the version/build persisted under `Keys.appVersion` / `Keys.appBuild`. Pure: the engine
/// turns each `Event` into a consent-gated `track()` call. Used on the SDK's serial queue only.
final class LifecycleEvents {
    static let installed = "Application Installed"
    static let updated = "Application Updated"
    static let opened = "Application Opened"
    static let backgrounded = "Application Backgrounded"

    /// One lifecycle event; `properties` keep insertion order for a stable payload.
    struct Event: Equatable {
        let name: String
        let properties: [(String, JSONValue)]

        static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.name == rhs.name && JSONValue.object(lhs.properties) == JSONValue.object(rhs.properties)
        }
    }

    private let keys: Keys
    private let storage: KeyValueStore
    private let currentVersion: String
    private let currentBuild: String

    init(keys: Keys, storage: KeyValueStore, currentVersion: String, currentBuild: String) {
        self.keys = keys
        self.storage = storage
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
    }

    /// On process start: `Application Installed` (nothing stored) or `Application Updated` (stored
    /// version/build differ), then always `Application Opened {from_background:false}`; persists
    /// the current version/build.
    func onLaunch() -> [Event] {
        let previousVersion = storage.get(keys.appVersion)
        let previousBuild = storage.get(keys.appBuild)
        var events: [Event] = []
        if previousVersion == nil && previousBuild == nil {
            events.append(Event(name: LifecycleEvents.installed, properties: [
                ("version", .string(currentVersion)),
                ("build", .string(currentBuild))
            ]))
        } else if previousVersion != currentVersion || previousBuild != currentBuild {
            events.append(Event(name: LifecycleEvents.updated, properties: [
                ("version", .string(currentVersion)),
                ("build", .string(currentBuild)),
                ("previous_version", previousVersion.map(JSONValue.string) ?? .null),
                ("previous_build", previousBuild.map(JSONValue.string) ?? .null)
            ]))
        }
        events.append(opened(fromBackground: false))
        storage.set(keys.appVersion, currentVersion)
        storage.set(keys.appBuild, currentBuild)
        return events
    }

    /// App returned to the foreground after a reported background.
    func onForeground() -> Event { opened(fromBackground: true) }

    /// App moved to the background; no properties.
    func onBackground() -> Event { Event(name: LifecycleEvents.backgrounded, properties: []) }

    private func opened(fromBackground: Bool) -> Event {
        Event(name: LifecycleEvents.opened, properties: [
            ("from_background", .bool(fromBackground)),
            ("version", .string(currentVersion)),
            ("build", .string(currentBuild))
        ])
    }
}
