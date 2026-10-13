import Foundation

/// Consent resolution state machine — port of `sdk/js/src/consent.ts`. Unresolved until a source
/// answers; precedence manual > cmp > storage > default — a weaker source never overwrites a
/// stronger one, a source may re-resolve itself. Listeners fire on every accepted (re-)resolution.
/// NOT thread-safe: used from the SDK's serial queue only.
final class ConsentManager {
    private let clock: Clock
    private var resolution: ResolvedConsent?
    private var listeners: [(ResolvedConsent) -> Void] = []

    init(clock: Clock) {
        self.clock = clock
    }

    /// Host-supplied consent — source `.manual`, always wins.
    func setConsent(_ input: ConsentInput) {
        var tcfString: String?
        if case let .tcf(s) = input { tcfString = s }
        accept(ResolvedConsent(
            signals: ConsentState.resolveSignals(input),
            input: input,
            tcfString: tcfString,
            gdprApplies: nil,
            source: .manual,
            ts: clock.nowMs()
        ))
    }

    /// Offer a non-manual resolution; rejected (`false`) when a strictly stronger source already resolved.
    @discardableResult
    func offer(_ resolution: ResolvedConsent) -> Bool {
        if let current = self.resolution, resolution.source < current.source { return false }
        accept(resolution)
        return true
    }

    /// Resolve with the configured default; no-op once resolved.
    func resolveDefault(granted: Bool) {
        guard resolution == nil else { return }
        accept(ResolvedConsent(signals: .uniform(granted), source: .default, ts: clock.nowMs()))
    }

    /// Register a listener fired on every accepted resolution.
    func onResolve(_ listener: @escaping (ResolvedConsent) -> Void) {
        listeners.append(listener)
    }

    func isResolved() -> Bool { resolution != nil }

    func getResolution() -> ResolvedConsent? { resolution }

    func getSignals() -> ConsentSignals? { resolution?.signals }

    /// The consent input for payload context: the host input when present, else a CMP-sourced TC
    /// string surfaces as `.tcf` so it rides on every event even though the host never called setConsent().
    func getConsent() -> ConsentInput? {
        guard let current = resolution else { return nil }
        if let input = current.input { return input }
        if let tcf = current.tcfString, !tcf.isEmpty { return .tcf(tcfString: tcf) }
        return nil
    }

    /// Back to unresolved; listeners stay registered.
    func clear() {
        resolution = nil
    }

    private func accept(_ resolution: ResolvedConsent) {
        self.resolution = resolution
        for listener in listeners { listener(resolution) }
    }
}
