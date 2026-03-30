import Foundation

class UsageAPI {
    private let oauthManager = OAuthManager()

    /// Fetch usage — if remoteURL is set, read from remote cache; otherwise query Anthropic directly.
    func fetchUsage() async -> UsageState {
        if let remoteURL = Self.remoteURL, !remoteURL.isEmpty {
            return await fetchFromRemote(remoteURL)
        }
        return await doFetch(retried: false)
    }

    // MARK: - Remote mode (client)

    static var remoteURL: String? {
        let saved = UserDefaults.standard.string(forKey: "remote_usage_url") ?? ""
        return saved.isEmpty ? nil : saved
    }

    static func setRemoteURL(_ url: String?) {
        UserDefaults.standard.set(url ?? "", forKey: "remote_usage_url")
    }

    static var isRemoteMode: Bool {
        if let url = remoteURL, !url.isEmpty { return true }
        return false
    }

    private func fetchFromRemote(_ urlString: String) async -> UsageState {
        // Normalize URL — append /usage if it looks like just a host:port
        let normalizedURL: String
        if urlString.hasSuffix("/usage") || urlString.hasSuffix("/usage/") {
            normalizedURL = urlString
        } else {
            let trimmed = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            normalizedURL = trimmed + "/usage"
        }

        guard let url = URL(string: normalizedURL) else {
            return .error("Invalid remote URL")
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 503 {
                    return .error("Remote: no data yet")
                }
                if httpResponse.statusCode != 200 {
                    return .error("Remote: HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            let usage = try decoder.decode(UsageResponse.self, from: data)
            return .loaded(usage)
        } catch {
            return .error("Remote: \(error.localizedDescription)")
        }
    }

    // MARK: - Local mode (server — direct Anthropic API)

    private func doFetch(retried: Bool) async -> UsageState {
        do {
            let token = try oauthManager.getAccessToken()

            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                return .error("Invalid URL")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    if !retried {
                        // Token might have been refreshed by Claude CLI in the meantime
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        return await doFetch(retried: true)
                    }
                    return .authNeeded
                }
                if httpResponse.statusCode != 200 {
                    return .error("HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            let usage = try decoder.decode(UsageResponse.self, from: data)
            return .loaded(usage)
        } catch is OAuthManager.OAuthError {
            return .noAuth
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
