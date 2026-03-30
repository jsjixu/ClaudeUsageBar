import Foundation
import Security

class OAuthManager {
    enum OAuthError: LocalizedError {
        case noCredentials
        case invalidCredentials
        case tokenExpired

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "No Claude Code credentials found — run `claude` CLI and log in"
            case .invalidCredentials: return "Invalid credentials format in Keychain"
            case .tokenExpired: return "OAuth token expired — run `claude` to refresh"
            }
        }
    }

    /// Read OAuth access token. Priority: CLIProxyAPI (auto-refreshing) > Keychain > file
    func getAccessToken() throws -> String {
        // 1. CLIProxyAPI — has refresh_token, auto-renews
        if let token = readFromCLIProxyAPI() {
            return token
        }

        // 2. Keychain (Claude Code CLI)
        if let token = readFromKeychain() {
            return token
        }

        // 3. Fallback: ~/.claude/.credentials.json
        if let token = readFromFile() {
            return token
        }

        throw OAuthError.noCredentials
    }

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

        return token
    }
}

