import Foundation

class CDPCookieManager {
    private var cachedCookies: String?
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 240  // Cache cookies for 4 minutes

    static var cdpHost: String {
        let saved = UserDefaults.standard.string(forKey: "cdp_host") ?? ""
        return saved.isEmpty ? "127.0.0.1" : saved
    }

    static var cdpPort: Int {
        let saved = UserDefaults.standard.integer(forKey: "cdp_port")
        return saved > 0 ? saved : 9222
    }

    func invalidateCache() {
        cachedCookies = nil
        cacheTime = nil
    }

    func fetchCookies() async throws -> String {
        // Return cached cookies if fresh
        if let cached = cachedCookies, let time = cacheTime,
           Date().timeIntervalSince(time) < cacheTTL {
            return cached
        }

        let host = CDPCookieManager.cdpHost
        let port = CDPCookieManager.cdpPort

        // Get browser-level WS endpoint
        let versionURL = URL(string: "http://\(host):\(port)/json/version")!
        let (data, _) = try await URLSession.shared.data(from: versionURL)

        guard let versionInfo = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let browserWS = versionInfo["webSocketDebuggerUrl"] as? String else {
            throw CDPError.invalidResponse
        }

        // Rewrite WS URL host — remote CDP returns ws://127.0.0.1:port/... but we need actual host
        let rewrittenWS: String
        if host != "127.0.0.1" && host != "localhost" {
            rewrittenWS = browserWS
                .replacingOccurrences(of: "ws://127.0.0.1:", with: "ws://\(host):")
                .replacingOccurrences(of: "ws://localhost:", with: "ws://\(host):")
        } else {
            rewrittenWS = browserWS
        }

        let cookies = try await extractCookies(browserWS: rewrittenWS)
        cachedCookies = cookies
        cacheTime = Date()
        return cookies
    }

    private func extractCookies(browserWS: String) async throws -> String {
        guard let url = URL(string: browserWS) else { throw CDPError.invalidURL }

        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        var msgID = 0
        func nextID() -> Int { msgID += 1; return msgID }

        func sendCommand(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
            let id = nextID()
            let cmd: [String: Any] = ["id": id, "method": method, "params": params]
            let cmdData = try JSONSerialization.data(withJSONObject: cmd)
            try await ws.send(.string(String(data: cmdData, encoding: .utf8)!))

            // Read messages until we get our response
            for _ in 0..<30 {
                let message = try await ws.receive()
                if case .string(let text) = message,
                   let respData = text.data(using: .utf8),
                   let resp = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                   (resp["id"] as? Int) == id {
                    return resp
                }
            }
            throw CDPError.invalidResponse
        }

        // 1. Create a background target (about:blank — invisible)
        let createResp = try await sendCommand("Target.createTarget", params: ["url": "about:blank"])
        guard let targetResult = createResp["result"] as? [String: Any],
              let targetId = targetResult["targetId"] as? String else {
            throw CDPError.invalidResponse
        }

        // 2. Attach to the new target to get a session
        let attachResp = try await sendCommand("Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true
        ])
        guard let attachResult = attachResp["result"] as? [String: Any],
              let sessionId = attachResult["sessionId"] as? String else {
            // Clean up and throw
            _ = try? await sendCommand("Target.closeTarget", params: ["targetId": targetId])
            throw CDPError.invalidResponse
        }

        // 3. Navigate to claude.ai to access cookies (uses existing session cookies from profile)
        let navID = nextID()
        let navCmd: [String: Any] = [
            "id": navID,
            "method": "Page.navigate",
            "params": ["url": "https://claude.ai/api/organizations"],
            "sessionId": sessionId
        ]
        let navData = try JSONSerialization.data(withJSONObject: navCmd)
        try await ws.send(.string(String(data: navData, encoding: .utf8)!))

        // Wait briefly for navigation
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        // 4. Get cookies from the session
        let cookieID = nextID()
        let cookieCmd: [String: Any] = [
            "id": cookieID,
            "method": "Network.getCookies",
            "params": ["urls": ["https://claude.ai"]],
            "sessionId": sessionId
        ]
        let cookieData = try JSONSerialization.data(withJSONObject: cookieCmd)
        try await ws.send(.string(String(data: cookieData, encoding: .utf8)!))

        var cookieStr = ""
        // Read until we find our cookie response
        for _ in 0..<30 {
            let message = try await ws.receive()
            if case .string(let text) = message,
               let respData = text.data(using: .utf8),
               let resp = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
               (resp["id"] as? Int) == cookieID {
                if let result = resp["result"] as? [String: Any],
                   let cookies = result["cookies"] as? [[String: Any]] {
                    cookieStr = cookies.compactMap { c -> String? in
                        guard let name = c["name"] as? String,
                              let value = c["value"] as? String else { return nil }
                        return "\(name)=\(value)"
                    }.joined(separator: "; ")
                }
                break
            }
        }

        // 5. Close the background target (cleanup!)
        let closeID = nextID()
        let closeCmd: [String: Any] = [
            "id": closeID,
            "method": "Target.closeTarget",
            "params": ["targetId": targetId]
        ]
        let closeData = try JSONSerialization.data(withJSONObject: closeCmd)
        try await ws.send(.string(String(data: closeData, encoding: .utf8)!))
        // Don't wait for response, we're closing anyway

        if cookieStr.isEmpty { throw CDPError.noCookies }
        return cookieStr
    }

    enum CDPError: LocalizedError {
        case invalidResponse
        case noTarget
        case invalidURL
        case noCookies

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid CDP response"
            case .noTarget: return "No browser tab found"
            case .invalidURL: return "Invalid WebSocket URL"
            case .noCookies: return "No cookies — login to claude.ai in Chrome CDP"
            }
        }
    }
}
