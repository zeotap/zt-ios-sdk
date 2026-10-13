import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Production `HTTPClient` over `URLSession`: one POST `dataTask` per call, explicit timeout, no
/// caching. The response body is read as UTF-8 (lossy, empty when absent) for every status, so the
/// transport can surface ingest's `{success, received, errors}` verdict and 4xx bodies. Connection
/// failures (`URLError` and friends) complete with `.failure`, which the transport treats as
/// retryable — a response with any status, including 5xx, is a `.success(HTTPResponse)`.
final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }

    func post(url: URL, headers: [String: String], body: Data, completion: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            completion(.success(HTTPResponse(status: http.statusCode, body: text)))
        }
        task.resume()
    }
}
