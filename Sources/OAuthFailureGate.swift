import Foundation
import Security

/// 双层 OAuth 刷新失败 Gate
/// - Terminal: invalid_grant 永久阻断，直到 Keychain 凭证变化
/// - Transient: 429/网络错误，指数退避 5min → 6h max
class OAuthFailureGate {

    enum BlockStatus {
        case allowed
        case terminalBlocked(reason: String)
        case transientBackoff(until: Date)
    }

    // UserDefaults keys
    private static let terminalBlockedKey = "oauthTerminalBlocked"
    private static let terminalReasonKey = "oauthTerminalReason"
    private static let terminalBlockedAtKey = "oauthTerminalBlockedAt"
    private static let transientBlockedUntilKey = "oauthTransientBlockedUntil"
    private static let transientFailureCountKey = "oauthTransientFailureCount"
    private static let keychainFingerprintKey = "oauthKeychainFingerprint"

    private static let baseInterval: TimeInterval = 300      // 5 min
    private static let maxInterval: TimeInterval = 21600     // 6 hours
    private static let terminalTTL: TimeInterval = 1800      // 30 min — terminal block expires

    /// 检查是否允许刷新
    static func shouldAttemptRefresh() -> BlockStatus {
        // Terminal check
        if UserDefaults.standard.bool(forKey: terminalBlockedKey) {
            // 检查 keychain fingerprint 是否变了
            if hasKeychainChanged() {
                clearAll()
                return .allowed
            }
            // TTL: terminal block expires after 30 min — allow retry
            if let blockedAt = UserDefaults.standard.object(forKey: terminalBlockedAtKey) as? Double {
                let elapsed = Date().timeIntervalSince1970 - blockedAt
                if elapsed > terminalTTL {
                    clearAll()
                    return .allowed
                }
            }
            let reason = UserDefaults.standard.string(forKey: terminalReasonKey) ?? "invalid_grant"
            return .terminalBlocked(reason: reason)
        }

        // Transient check
        if let blockedUntilRaw = UserDefaults.standard.object(forKey: transientBlockedUntilKey) as? Double {
            let blockedUntil = Date(timeIntervalSince1970: blockedUntilRaw)
            if blockedUntil > Date() {
                // 仍在退避中，但检查 keychain 是否变了
                if hasKeychainChanged() {
                    clearAll()
                    return .allowed
                }
                return .transientBackoff(until: blockedUntil)
            }
            // 退避已过期，清除
            clearTransient()
        }

        return .allowed
    }

    /// 记录 terminal 失败（invalid_grant / 400）
    static func recordTerminalFailure(reason: String = "invalid_grant") {
        UserDefaults.standard.set(true, forKey: terminalBlockedKey)
        UserDefaults.standard.set(reason, forKey: terminalReasonKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: terminalBlockedAtKey)
        clearTransient()
        saveCurrentFingerprint()
    }

    /// 记录 transient 失败（429、网络错误）
    static func recordTransientFailure() {
        // 如果已经 terminal 阻断，不降级
        guard !UserDefaults.standard.bool(forKey: terminalBlockedKey) else { return }

        let count = UserDefaults.standard.integer(forKey: transientFailureCountKey) + 1
        UserDefaults.standard.set(count, forKey: transientFailureCountKey)

        let interval = cooldownInterval(failures: count)
        let blockedUntil = Date().addingTimeInterval(interval)
        UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: transientBlockedUntilKey)

        saveCurrentFingerprint()
    }

    /// Delegated CLI refresh 成功后清除所有 gate（CLI 拿到了新 token）
    static func clearForDelegatedRefreshSuccess() {
        clearAll()
    }

    /// 刷新成功，清除所有 gate
    static func recordSuccess() {
        clearAll()
    }

    /// 指数退避: 5min * 2^(n-1), max 6h
    private static func cooldownInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(failures - 1))
        return min(baseInterval * factor, maxInterval)
    }

    private static func clearAll() {
        UserDefaults.standard.removeObject(forKey: terminalBlockedKey)
        UserDefaults.standard.removeObject(forKey: terminalReasonKey)
        UserDefaults.standard.removeObject(forKey: terminalBlockedAtKey)
        clearTransient()
        UserDefaults.standard.removeObject(forKey: keychainFingerprintKey)
    }

    private static func clearTransient() {
        UserDefaults.standard.removeObject(forKey: transientBlockedUntilKey)
        UserDefaults.standard.removeObject(forKey: transientFailureCountKey)
    }

    // MARK: - Keychain fingerprint

    private static func saveCurrentFingerprint() {
        if let fp = currentCredentialsFingerprint() {
            UserDefaults.standard.set(fp, forKey: keychainFingerprintKey)
        }
    }

    private static func hasKeychainChanged() -> Bool {
        guard let saved = UserDefaults.standard.string(forKey: keychainFingerprintKey) else { return false }
        guard let current = currentCredentialsFingerprint() else { return false }
        return current != saved
    }

    /// Fingerprint over ALL credential sources (Keychain + file) so gate clears
    /// when either source is updated (e.g. `claude login` updates file but not Keychain).
    private static func currentCredentialsFingerprint() -> String? {
        var hash: UInt64 = 5381
        var hasAny = false

        // Keychain data
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            for byte in data { hash = hash &* 31 &+ UInt64(byte) }
            hasAny = true
        }

        // File data
        let filePath = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        if let fileData = FileManager.default.contents(atPath: filePath) {
            for byte in fileData { hash = hash &* 31 &+ UInt64(byte) }
            hasAny = true
        }

        return hasAny ? String(hash) : nil
    }
}
