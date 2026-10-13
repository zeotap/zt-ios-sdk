import Foundation
import Network

/// A tiny in-process HTTP/1.1 server standing in for ingest during XCUITests: accepts
/// `POST /v1/batch`, records every event, answers `{"success":true,"received":n}` (or a scripted
/// status), and exposes the received batches to the Received screen.
final class IngestStubServer: ObservableObject {
    struct ReceivedEvent: Identifiable {
        let id = UUID()
        let messageId: String
        let type: String
        let name: String
        let raw: String
    }

    @Published private(set) var events: [ReceivedEvent] = []
    @Published private(set) var requestCount = 0
    var nextStatus = 200

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ingest-stub")
    private(set) var port: UInt16 = 0

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self, error == nil else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if let request = self.parse(buffer) {
                    self.respond(to: request, on: connection)
                } else if isComplete {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
        receive()
    }

    private struct Request {
        let method: String
        let path: String
        let body: Data
    }

    private func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
            return Int(kv[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        var received = 0
        if request.method == "POST", request.path.hasPrefix("/v1/batch"),
           let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let batch = json["batch"] as? [[String: Any]] {
            received = batch.count
            let parsed = batch.map { event in
                ReceivedEvent(
                    messageId: event["messageId"] as? String ?? "",
                    type: event["type"] as? String ?? "",
                    name: (event["event"] as? String) ?? (event["name"] as? String) ?? "",
                    raw: String(decoding: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), as: UTF8.self)
                )
            }
            DispatchQueue.main.async {
                self.events.append(contentsOf: parsed)
                self.requestCount += 1
            }
        }
        let status = nextStatus
        let body = status == 200 ? "{\"success\":true,\"received\":\(received)}" : "{\"error\":\"stubbed \(status)\"}"
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
