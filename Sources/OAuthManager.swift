import Foundation
import Security

class OAuthManager {
    enum OAuthError: LocalizedError {
        case noCredentials
        case invalidCredentials
        case tokenExpired
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "No Claude Code credentials found — run `claude` CLI and log in"
            case .invalidCredentials: return "Invalid credentials format in Keychain"
            case .tokenExpired: return "OAuth token expired — run `claude` to refresh"
            case .rateLimited: return "OAuth refresh rate limited — backing off"
            }
        }
    }

    private var cachedToken: String?
    private var cacheExpiry: Date?

    /// Read OAuth access token. Priority: CLIProxyAPI > Memory cache > Keychain > File > Refresh
    func getAccessToken() async throws -> String {
        // 1. CLIProxyAPI — has refresh_token, auto-renews
        if let token = readFromCLIProxyAPI() {
            return token
        }

        // 2. Memory cache
        if let token = cachedToken, let expiry = cacheExpiry, expiry > Date() {
            return token
        }

        // 3. Keychain (Claude Code CLI) — valid (not expired) access token
        if let token = readFromKeychain() {
            return token
        }

        // 4. File — valid (not expired) access token
        if let token = readFromFile() {
            return token
        }

        // 5. Try refresh using refreshToken from keychain or file
        if let refreshToken = readRefreshTokenFromKeychain() ?? readRefreshTokenFromFile() {
            switch OAuthFailureGate.shouldAttemptRefresh() {
            case .allowed:
                return try await refreshAccessToken(refreshToken: refreshToken)
            case .terminalBlocked:
                throw OAuthError.tokenExpired
            case .transientBackoff:
                throw OAuthError.rateLimited
            }
        }

        throw OAuthError.noCredentials
    }

    /// Check if any credential source has an unexpired access token (no refresh, no network).
    func hasValidToken() -> Bool {
        if readFromCLIProxyAPI() != nil { return true }
        if readFromKeychain() != nil { return true }
        if readFromFile() != nil { return true }
        return false
    }

    /// Invalidate memory cache — call on 401 before retrying so refresh is attempted
    func invalidateCache() {
        cachedToken = nil
        cacheExpiry = nil
    }

    // MARK: - Token sources

    /// Read from ~/.cli-proxy-api/claude-*.json (CLIProxyAPI with auto-refresh)
    private func readFromCLIProxyAPI() -> String? {
        let dir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }

        // Find claude-*.json files
        let claudeFiles = files.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
        guard let filename = claudeFiles.first else { return nil }

        let path = (dir as NSString).appendingPathComponent(filename)
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              !token.isEmpty else {
            return nil
        }

        // Check expiry if available
        if let expiryStr = json["expired"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
            if let expiry = formatter.date(from: expiryStr), expiry < Date() {
                return nil  // Token expired, fall through to next source
            }
        }

        return token
    }

    private func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }

        // Check expiry
        if let expiresAt = oauth["expiresAt"] as? Double {
            if Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
                return nil  // Expired, fall through
            }
        }

        return token
    }

    private func readFromFile() -> String? {
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }

        // Check expiry
        if let expiresAt = oauth["expiresAt"] as? Double {
            if Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
                return nil  // Expired, fall through to refresh
            }
        }

        return token
    }

    private func readRefreshTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            return nil
        }

        return refreshToken
    }

    private func readRefreshTokenFromFile() -> String? {
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            return nil
        }

        return refreshToken
    }

    // MARK: - Token refresh

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        ]
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            OAuthFailureGate.recordTransientFailure()
            throw OAuthError.tokenExpired
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 400:
            OAuthFailureGate.recordTerminalFailure(reason: "invalid_grant")
            throw OAuthError.tokenExpired
        case 429:
            OAuthFailureGate.recordTransientFailure()
            throw OAuthError.rateLimited
        default:
            OAuthFailureGate.recordTransientFailure()
            throw OAuthError.tokenExpired
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            OAuthFailureGate.recordTransientFailure()
            throw OAuthError.invalidCredentials
        }

        let expiresIn = json["expires_in"] as? Double ?? 3600
        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken

        cachedToken = accessToken
        cacheExpiry = Date().addingTimeInterval(expiresIn - 60)  // 1-minute buffer

        OAuthFailureGate.recordSuccess()
        persistCredentials(accessToken: accessToken, refreshToken: newRefreshToken, expiresIn: expiresIn)

        return accessToken
    }

    private func persistCredentials(accessToken: String, refreshToken: String, expiresIn: Double) {
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        let json: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": expiresAt
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
