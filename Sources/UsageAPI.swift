import Foundation

// MARK: - FailureGate

/// Tracks consecutive API failures and suggests retry intervals to prevent hammering.
class FailureGate {
    private(set) var consecutiveFailures: Int = 0
    private(set) var isTerminalAuthBlock: Bool = false
    private(set) var suggestedInterval: TimeInterval = 300

    func recordSuccess() {
        consecutiveFailures = 0
        isTerminalAuthBlock = false
        suggestedInterval = 300
    }

    /// Mark a 401/403 terminal auth failure. Polls every 60s to detect credential changes.
    func recordAuthFailure() {
        isTerminalAuthBlock = true
        suggestedInterval = 60
    }

    /// Respect server's Retry-After, bounded to [60s, 10min].
    func recordRateLimited(retryAfter: TimeInterval) {
        suggestedInterval = min(max(retryAfter, 60), 600)
    }

    /// Increment failure count. Returns true if this error should be suppressed
    /// (first failure when prior good data exists — treated as a flake).
    func recordError(hasPriorGoodData: Bool) -> Bool {
        consecutiveFailures += 1
        if consecutiveFailures == 1 && hasPriorGoodData {
            suggestedInterval = 300  // Keep normal pace for first flake
            return true  // Suppressed
        }
        let doublings = max(consecutiveFailures - 2, 0)
        suggestedInterval = min(300.0 * pow(2.0, Double(doublings)), 21600)
        return false
    }

    func clearTerminalBlock() {
        isTerminalAuthBlock = false
        consecutiveFailures = 0
        suggestedInterval = 300
    }
}

// MARK: - UsageAPI

/// File-based debug logger (NSLog is invisible on macOS 26)
func debugLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(msg)\n"
    let path = NSString(string: "~/.openclaw/logs/usage-bar-debug.log").expandingTildeInPath
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

class UsageAPI {
    let oauthManager = OAuthManager()
    let gate = FailureGate()
    private var lastGoodUsage: UsageResponse?
    /// Use ephemeral session to avoid HTTP/2 connection reuse after 429
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func fetchUsage() async -> UsageState {
        // Skip the API call if we're in a terminal auth block unless a valid token appeared
        if gate.isTerminalAuthBlock {
            if oauthManager.hasValidToken() {
                gate.clearTerminalBlock()
            } else {
                return .authNeeded
            }
        }

        let result = await doFetch(retried: false)

        switch result {
        case .loaded(let usage):
            gate.recordSuccess()
            lastGoodUsage = usage
        case .authNeeded:
            gate.recordAuthFailure()
        case .rateLimited(let retryAfter):
            gate.recordRateLimited(retryAfter: retryAfter)
        case .error:
            if gate.recordError(hasPriorGoodData: lastGoodUsage != nil), let usage = lastGoodUsage {
                return .loaded(usage)  // Suppress first flake — return cached data
            }
        default:
            break
        }

        return result
    }

    // MARK: - Direct Anthropic API

    private func doFetch(retried: Bool) async -> UsageState {
        do {
            let token = try await oauthManager.getAccessToken()
            debugLog("[UsageAPI] token: \(token.prefix(15))...")

            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                return .error("Invalid URL")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                debugLog("[UsageAPI] HTTP status: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    if !retried {
                        debugLog("[UsageAPI] 401/403 — invalidating cache, will retry")
                        oauthManager.invalidateCache()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        return await doFetch(retried: true)
                    }
                    debugLog("[UsageAPI] 401/403 after retry — entering authNeeded")
                    return .authNeeded
                }
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Double($0) } ?? 60
                    debugLog("[UsageAPI] 429 from usage API! retryAfter=\(retryAfter)")
                    return .rateLimited(retryAfter: retryAfter)
                }
                if httpResponse.statusCode != 200 {
                    return .error("HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            let usage = try decoder.decode(UsageResponse.self, from: data)
            return .loaded(usage)
        } catch OAuthManager.OAuthError.rateLimited {
            debugLog("[UsageAPI] OAuthError.rateLimited — OAuth refresh endpoint returned 429")
            // OAuth refresh was rate-limited — back off with a default interval
            return .rateLimited(retryAfter: 300)
        } catch let error as OAuthManager.OAuthError {
            debugLog("[UsageAPI] OAuthError: \(error.localizedDescription)")
            return .noAuth
        } catch {
            debugLog("[UsageAPI] generic error: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }
}
