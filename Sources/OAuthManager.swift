import Foundation
import Security

// MARK: - Delegated CLI Refresh

/// Let `claude` CLI handle OAuth token refresh via Keychain.
/// Instead of calling platform.claude.com directly (which triggers rate limits),
/// we run `claude -p "ping"` which triggers the CLI's own refresh logic,
/// then detect the Keychain change.
enum DelegatedCLIRefresh {

    enum Outcome {
        case succeeded
        case cliUnavailable
        case skippedByCooldown
        case failed(String)
    }

    // MARK: - Cooldown

    private static let lastAttemptKey = "delegatedCLIRefreshLastAttemptAt"
    private static let cooldownSecondsKey = "delegatedCLIRefreshCooldownSeconds"
    private static let successCooldown: TimeInterval = 300   // 5 minutes
    private static let failureCooldown: TimeInterval = 20    // 20 seconds

    static func attempt() async -> Outcome {
        if isInCooldown() {
            return .skippedByCooldown
        }

        guard isClaudeCLIAvailable() else {
            return .cliUnavailable
        }

        let baseline = currentKeychainFingerprint()

        let touchSuccess = await runClaudePing(timeout: 10)

        let changed = await waitForKeychainChange(from: baseline, timeout: 3.0, interval: 0.5)

        if changed {
            recordAttempt(cooldown: successCooldown)
            return .succeeded
        }

        recordAttempt(cooldown: failureCooldown)
        if !touchSuccess {
            return .failed("claude -p ping exited with error or timed out")
        }
        return .failed("Keychain did not update after claude CLI ping")
    }

    static func isInCooldown() -> Bool {
        let defaults = UserDefaults.standard
        guard let lastAttempt = defaults.object(forKey: lastAttemptKey) as? Double else {
            return false
        }
        let cooldown = defaults.double(forKey: cooldownSecondsKey)
        guard cooldown > 0 else { return false }
        return Date().timeIntervalSince1970 - lastAttempt < cooldown
    }

    private static func isClaudeCLIAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runClaudePing(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude", "-p", "ping"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            var didResume = false
            let lock = NSLock()

            let timeoutItem = DispatchWorkItem {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                if process.isRunning { process.terminate() }
                continuation.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                continuation.resume(returning: false)
            }
        }
    }

    private static func currentKeychainFingerprint() -> UInt64 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return 0
        }

        var hash: UInt64 = 5381
        for byte in data { hash = hash &* 31 &+ UInt64(byte) }
        return hash
    }

    private static func waitForKeychainChange(from baseline: UInt64, timeout: TimeInterval, interval: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if baseline != 0 && currentKeychainFingerprint() != baseline {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return false
            }
        }
        return baseline != 0 && currentKeychainFingerprint() != baseline
    }

    private static func recordAttempt(cooldown: TimeInterval) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: lastAttemptKey)
        defaults.set(cooldown, forKey: cooldownSecondsKey)
    }
}

// MARK: - OAuthManager

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

        // 5. Delegated CLI Refresh — let `claude` CLI handle the refresh
        let cliOutcome = await DelegatedCLIRefresh.attempt()
        switch cliOutcome {
        case .succeeded:
            OAuthFailureGate.clearForDelegatedRefreshSuccess()
            // Re-read from Keychain/File after CLI refreshed them
            if let token = readFromKeychain() { return token }
            if let token = readFromFile() { return token }
            // CLI said success but we still can't read — fall through to OAuth refresh
        case .cliUnavailable, .skippedByCooldown, .failed:
            break  // Fall through to OAuth refresh
        }

        // 6. OAuth refresh — direct HTTP call (fallback)
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

    /// Check if any credential source can provide a token (valid access token OR refreshable).
    func hasValidToken() -> Bool {
        if readFromCLIProxyAPI() != nil { return true }
        if readFromKeychain() != nil { return true }
        if readFromFile() != nil { return true }
        // Also consider refreshable — if we have a refresh_token and gate allows it
        if readRefreshTokenFromKeychain() != nil || readRefreshTokenFromFile() != nil {
            if case .allowed = OAuthFailureGate.shouldAttemptRefresh() { return true }
        }
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
        let expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        let oauthPayload: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": expiresAt
            ]
        ]

        // Write to file
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: oauthPayload, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: path, contents: data)
        }

        // Write to Keychain — keep both sources in sync
        persistToKeychain(oauthPayload)
    }

    private func persistToKeychain(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let service = "Claude Code-credentials"

        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        if status == errSecItemNotFound {
            // Insert new
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccount as String] = NSUserName()
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }
}
