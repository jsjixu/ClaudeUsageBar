import Foundation

class UsageAPI {
    private let oauthManager = OAuthManager()

    func fetchUsage() async -> UsageState {
        return await doFetch(retried: false)
    }

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
