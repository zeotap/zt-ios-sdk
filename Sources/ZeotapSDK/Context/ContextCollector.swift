import Foundation

/// Supplies the mobile context blocks the web SDK never sends, in the order they appear in
/// `context` (after `library`): app, device, os, network, screen, locale, timezone, userAgent.
/// Static blocks are computed once; `network` is refreshed per event. Privacy defaults: no device
/// name, no carrier (CoreTelephony is deprecated/placeholder since iOS 16.4), advertising id only
/// when opted in.
protocol ContextCollector: AnyObject {
    /// Ordered context entries to append after `library`.
    func collect() -> [(String, JSONValue)]
}
