import Foundation

/// URLSession delegate that accepts self-signed certificates for CDP bridge
class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

class CDPCookieManager {
    private var cachedCookies: String?
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 240  // Cache cookies for 4 minutes

    // Persistent background tab for session keep-alive
    private var persistentTargetId: String?
    private var persistentSessionId: String?

    // URLSession that accepts self-signed certs (for remote HTTPS bridge)
    private lazy var trustingSession: URLSession = {
        URLSession(configuration: .default, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
    }()

    static var cdpHost: String {
        let saved = UserDefaults.standard.string(forKey: "cdp_host") ?? ""
        return saved.isEmpty ? "127.0.0.1" : saved
    }

    static var cdpPort: Int {
        let saved = UserDefaults.standard.integer(forKey: "cdp_port")
        return saved > 0 ? saved : 9222
    }

    /// Whether we're connecting to a remote host (needs HTTPS)
    private static var isRemote: Bool {
        let h = cdpHost
        return h != "127.0.0.1" && h != "localhost"
    }

    /// URL scheme based on local vs remote
    private static var httpScheme: String { isRemote ? "https" : "http" }
    private static var wsScheme: String { isRemote ? "wss" : "ws" }

    func invalidateCache() {
        // Close the old persistent tab if it exists
        if let targetId = persistentTargetId {
            let host = CDPCookieManager.cdpHost
            let port = CDPCookieManager.cdpPort
            Task {
                await closePersistentTab(host: host, port: port, targetId: targetId)
            }
        }
        cachedCookies = nil
        cacheTime = nil
        persistentTargetId = nil
        persistentSessionId = nil
    }

    /// Close a CDP target by ID via HTTP(S) endpoint
    private func closePersistentTab(host: String, port: Int, targetId: String) async {
        let scheme = CDPCookieManager.httpScheme
        guard let url = URL(string: "\(scheme)://\(host):\(port)/json/close/\(targetId)") else { return }
        _ = try? await trustingSession.data(from: url)
    }

    func fetchCookies() async throws -> String {
        // Return cached cookies if fresh
        if let cached = cachedCookies, let time = cacheTime,
           Date().timeIntervalSince(time) < cacheTTL {
            return cached
        }

        let host = CDPCookieManager.cdpHost
        let port = CDPCookieManager.cdpPort
        let scheme = CDPCookieManager.httpScheme

        // Get browser-level WS endpoint
        let versionURL = URL(string: "\(scheme)://\(host):\(port)/json/version")!
        let (data, _) = try await trustingSession.data(from: versionURL)

        guard let versionInfo = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let browserWS = versionInfo["webSocketDebuggerUrl"] as? String else {
            throw CDPError.invalidResponse
        }

        // Rewrite WS URL — remote CDP returns ws://127.0.0.1:9222/... but we need wss://host:port/...
        let rewrittenWS: String
        if CDPCookieManager.isRemote {
            let wsScheme = CDPCookieManager.wsScheme
            rewrittenWS = browserWS
                .replacingOccurrences(of: "ws://127.0.0.1:9222", with: "\(wsScheme)://\(host):\(port)")
                .replacingOccurrences(of: "ws://localhost:9222", with: "\(wsScheme)://\(host):\(port)")
        } else {
            rewrittenWS = browserWS
        }

        let cookies = try await extractCookiesWithKeepAlive(browserWS: rewrittenWS)
        cachedCookies = cookies
        cacheTime = Date()
        return cookies
    }

    /// Check if our persistent tab is still alive
    private func isPersistentTabAlive(host: String, port: Int) async -> Bool {
        guard let targetId = persistentTargetId else { return false }
        let scheme = CDPCookieManager.httpScheme
        guard let url = URL(string: "\(scheme)://\(host):\(port)/json/list") else { return false }
        do {
            let (data, _) = try await trustingSession.data(from: url)
            let tabs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            return tabs.contains { ($0["id"] as? String) == targetId }
        } catch {
            return false
        }
    }

    private func extractCookiesWithKeepAlive(browserWS: String) async throws -> String {
        guard let url = URL(string: browserWS) else { throw CDPError.invalidURL }

        let host = CDPCookieManager.cdpHost
        let port = CDPCookieManager.cdpPort

        // Use trusting session for WSS with self-signed certs
        let ws = trustingSession.webSocketTask(with: url)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        var msgID = 0
        func nextID() -> Int { msgID += 1; return msgID }

        func sendCommand(_ method: String, params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
            let id = nextID()
            var cmd: [String: Any] = ["id": id, "method": method, "params": params]
            if let sid = sessionId { cmd["sessionId"] = sid }
            let cmdData = try JSONSerialization.data(withJSONObject: cmd)
            try await ws.send(.string(String(data: cmdData, encoding: .utf8)!))

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

        // Check if persistent tab is still alive
        let tabAlive = await isPersistentTabAlive(host: host, port: port)

        let targetId: String
        let sessionId: String

        if tabAlive, let tid = persistentTargetId {
            targetId = tid
            let attachResp = try await sendCommand("Target.attachToTarget", params: [
                "targetId": targetId,
                "flatten": true
            ])
            guard let attachResult = attachResp["result"] as? [String: Any],
                  let sid = attachResult["sessionId"] as? String else {
                persistentTargetId = nil
                persistentSessionId = nil
                return try await createPersistentTabAndExtract(ws: ws, nextID: &msgID)
            }
            sessionId = sid
        } else {
            return try await createPersistentTabAndExtract(ws: ws, nextID: &msgID)
        }

        let cookies = try await getCookiesFromSession(ws: ws, sessionId: sessionId, msgID: &msgID)

        let detachID = msgID + 1; msgID = detachID
        let detachCmd: [String: Any] = [
            "id": detachID,
            "method": "Target.detachFromTarget",
            "params": ["sessionId": sessionId]
        ]
        let detachData = try JSONSerialization.data(withJSONObject: detachCmd)
        try? await ws.send(.string(String(data: detachData, encoding: .utf8)!))

        if cookies.isEmpty { throw CDPError.noCookies }
        return cookies
    }

    private func createPersistentTabAndExtract(ws: URLSessionWebSocketTask, nextID msgID: inout Int) async throws -> String {
        func nextID() -> Int { msgID += 1; return msgID }

        func sendCommand(_ method: String, params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
            let id = nextID()
            var cmd: [String: Any] = ["id": id, "method": method, "params": params]
            if let sid = sessionId { cmd["sessionId"] = sid }
            let cmdData = try JSONSerialization.data(withJSONObject: cmd)
            try await ws.send(.string(String(data: cmdData, encoding: .utf8)!))

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

        // Clean up any orphaned claude.ai tabs before creating a new one
        let host = CDPCookieManager.cdpHost
        let port = CDPCookieManager.cdpPort
        let scheme = CDPCookieManager.httpScheme
        if let listURL = URL(string: "\(scheme)://\(host):\(port)/json/list"),
           let (listData, _) = try? await trustingSession.data(from: listURL),
           let tabs = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] {
            for tab in tabs {
                if let url = tab["url"] as? String, url.contains("claude.ai"),
                   let tabId = tab["id"] as? String {
                    await closePersistentTab(host: host, port: port, targetId: tabId)
                }
            }
        }

        // Create persistent tab — load claude.ai so frontend JS keeps session alive
        let createResp = try await sendCommand("Target.createTarget", params: ["url": "https://claude.ai"])
        guard let targetResult = createResp["result"] as? [String: Any],
              let targetId = targetResult["targetId"] as? String else {
            throw CDPError.invalidResponse
        }

        let attachResp = try await sendCommand("Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true
        ])
        guard let attachResult = attachResp["result"] as? [String: Any],
              let sessionId = attachResult["sessionId"] as? String else {
            _ = try? await sendCommand("Target.closeTarget", params: ["targetId": targetId])
            throw CDPError.invalidResponse
        }

        persistentTargetId = targetId
        persistentSessionId = sessionId

        try await Task.sleep(nanoseconds: 3_000_000_000) // 3s for full page

        let cookies = try await getCookiesFromSession(ws: ws, sessionId: sessionId, msgID: &msgID)

        let detachID = msgID + 1; msgID = detachID
        let detachCmd: [String: Any] = [
            "id": detachID,
            "method": "Target.detachFromTarget",
            "params": ["sessionId": sessionId]
        ]
        let detachData = try JSONSerialization.data(withJSONObject: detachCmd)
        try? await ws.send(.string(String(data: detachData, encoding: .utf8)!))

        if cookies.isEmpty { throw CDPError.noCookies }
        return cookies
    }

    private func getCookiesFromSession(ws: URLSessionWebSocketTask, sessionId: String, msgID: inout Int) async throws -> String {
        let cookieID = msgID + 1; msgID = cookieID
        let cookieCmd: [String: Any] = [
            "id": cookieID,
            "method": "Network.getCookies",
            "params": ["urls": ["https://claude.ai"]],
            "sessionId": sessionId
        ]
        let cookieData = try JSONSerialization.data(withJSONObject: cookieCmd)
        try await ws.send(.string(String(data: cookieData, encoding: .utf8)!))

        for _ in 0..<30 {
            let message = try await ws.receive()
            if case .string(let text) = message,
               let respData = text.data(using: .utf8),
               let resp = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
               (resp["id"] as? Int) == cookieID {
                if let result = resp["result"] as? [String: Any],
                   let cookies = result["cookies"] as? [[String: Any]] {
                    return cookies.compactMap { c -> String? in
                        guard let name = c["name"] as? String,
                              let value = c["value"] as? String else { return nil }
                        return "\(name)=\(value)"
                    }.joined(separator: "; ")
                }
                break
            }
        }
        return ""
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
