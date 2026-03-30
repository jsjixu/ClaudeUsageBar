import Foundation
import Network

/// Lightweight HTTP server that serves cached usage JSON on port 9876.
/// Only active in "local" mode (the machine that actually queries Anthropic).
class UsageServer {
    private var listener: NWListener?
    private var cachedJSON: Data?
    private var cachedAt: Date?
    let port: UInt16

    init(port: UInt16 = 9876) {
        self.port = port
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            print("UsageServer: failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("UsageServer: listening on port \(nwPort)")
            case .failed(let err):
                print("UsageServer: failed — \(err)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func updateCache(_ response: UsageResponse) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        cachedJSON = try? encoder.encode(response)
        cachedAt = Date()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))

        // Read the HTTP request (we only care about any incoming data to trigger a response)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self else {
                connection.cancel()
                return
            }

            // Parse request line to check path
            var isUsagePath = true
            if let data = data, let request = String(data: data, encoding: .utf8) {
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                // Accept GET /usage or GET /
                if !firstLine.contains("/usage") && !firstLine.contains("/ ") && !firstLine.contains("/ HTTP") {
                    // Return 404 for unknown paths
                    isUsagePath = false
                }
            }

            let responseData: Data
            if !isUsagePath {
                let body = "{\"error\":\"not found\"}"
                let header = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                responseData = Data((header + body).utf8)
            } else if let json = self.cachedJSON, let cachedAt = self.cachedAt {
                let age = Int(Date().timeIntervalSince(cachedAt))
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Cached-Age: \(age)\r\nContent-Length: \(json.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                responseData = Data(header.utf8) + json
            } else {
                let body = "{\"error\":\"no data yet\"}"
                let header = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                responseData = Data((header + body).utf8)
            }

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
