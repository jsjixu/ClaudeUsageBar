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

    /// Read OAuth access token from macOS Keychain (written by Claude Code CLI)
    func getAccessToken() throws -> String {
        // Try Keychain first
        if let token = readFromKeychain() {
            return token
        }

        // Fallback: ~/.claude/.credentials.json
        if let token = readFromFile() {
            return token
        }

        throw OAuthError.noCredentials
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
