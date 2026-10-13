import Foundation

struct HTTPResponse: Equatable, Sendable {
    let status: Int
    let body: String
}

/// Minimal async HTTP POST. Production: `URLSession`; tests: scripted responses. Connection
/// failures surface as an `Error` (retryable, like the web's thrown `fetch()`).
protocol HTTPClient: Sendable {
    func post(url: URL, headers: [String: String], body: Data, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void)
}
