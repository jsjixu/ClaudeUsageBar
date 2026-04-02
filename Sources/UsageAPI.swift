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

class UsageAPI {
    private let oauthManager = OAuthManager()
    let gate = FailureGate()
    private var lastGoodUsage: UsageResponse?

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
            NSLog("[UsageAPI] getAccessToken result: %@", String(token.prefix(15)))

            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                return .error("Invalid URL")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                NSLog("[UsageAPI] HTTP status: %d", httpResponse.statusCode)
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    if !retried {
                        // Invalidate cache and retry — OAuthManager will attempt a token refresh
                        oauthManager.invalidateCache()
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        return await doFetch(retried: true)
                    }
                    return .authNeeded
                }
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Double($0) } ?? 60
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
            NSLog("[UsageAPI] catch OAuthError: rateLimited")
            // OAuth refresh was rate-limited — back off with a default interval
            return .rateLimited(retryAfter: 300)
        } catch let error as OAuthManager.OAuthError {
            NSLog("[UsageAPI] catch OAuthError: %@", error.localizedDescription)
            return .noAuth
        } catch {
            NSLog("[UsageAPI] catch generic error: %@", error.localizedDescription)
            return .error(error.localizedDescription)
        }
    }
}
