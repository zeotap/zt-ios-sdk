import Foundation

/// Errors thrown by `configure` or delivered to callbacks / `SdkListener`. Callback-facing
/// messages are byte-identical to the browser SDK's.
public enum ZeotapError: Error, Equatable, LocalizedError, Sendable {
    /// `configure` with an empty write key.
    case missingWriteKey
    /// `apiHost` empty or not an http(s) URL.
    case invalidApiHost(String)
    /// Another configuration value out of range.
    case invalidConfiguration(String)
    /// A facade method was called before `configure`.
    case notConfigured(method: String)
    /// Pre-consent buffer at `maxBufferedEvents`; the newest event was dropped.
    case preConsentBufferFull
    /// Consent resolved denied for this call's signal (`what` = event type or "identity update").
    case consentDenied(what: String, signal: String)
    /// `setUserIdentities` while identify consent is already denied.
    case identitiesDenied
    /// A property value the SDK cannot serialise.
    case invalidProperties(key: String)
    /// Ingest answered a non-retryable 4xx; the batch was dropped.
    case ingestRejected(status: Int, body: String)
    /// Ingest answered 200 with `success: false`.
    case ingestPartialFailure(received: Int, errors: [String])
    /// Retries exhausted; the batch stays queued.
    case deliveryFailed(attempts: Int, description: String)
    /// Queue / key-value store failure.
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .missingWriteKey: return "[SDK] writeKey is required"
        case let .invalidApiHost(host): return "[SDK] apiHost is required and must be an http(s) URL (got \"\(host)\")"
        case let .invalidConfiguration(detail): return "[SDK] \(detail)"
        case let .notConfigured(method): return "[SDK] Not initialized. Call configure() before \(method)()."
        case .preConsentBufferFull: return "[SDK] Event dropped: pre-consent buffer full"
        case let .consentDenied(what, signal): return "[SDK] Dropped \(what): no \(signal) consent"
        case .identitiesDenied: return "[SDK] Identities dropped: no identify consent"
        case let .invalidProperties(key): return "[SDK] Unsupported property value for key \"\(key)\""
        case let .ingestRejected(status, body): return "Ingest API error \(status): \(body)"
        case let .ingestPartialFailure(received, errors): return "[SDK] Ingest accepted \(received) event(s) with errors: \(errors)"
        case let .deliveryFailed(attempts, description): return "[SDK] Failed to send after \(attempts) attempts: \(description)"
        case let .storage(detail): return "[SDK] Storage error: \(detail)"
        }
    }
}
