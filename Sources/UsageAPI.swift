import Foundation

class UsageAPI {
    private let orgID = "ec954bf6-ee1a-418e-92d1-bef93b5faed9"
    private let cookieManager = CDPCookieManager()

    func invalidateCookieCache() {
        cookieManager.invalidateCache()
    }

    func fetchUsage() async -> UsageState {
        return await doFetch(retried: false)
    }

    private func doFetch(retried: Bool) async -> UsageState {
        do {
            let cookies = try await cookieManager.fetchCookies()
            let urlStr = "https://claude.ai/api/organizations/\(orgID)/usage"
            guard let url = URL(string: urlStr) else { return .error("Invalid URL") }

            var request = URLRequest(url: url)
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
            request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("\"Chromium\";v=\"146\", \"Not=A?Brand\";v=\"99\"", forHTTPHeaderField: "Sec-Ch-Ua")
            request.setValue("?0", forHTTPHeaderField: "Sec-Ch-Ua-Mobile")
            request.setValue("\"macOS\"", forHTTPHeaderField: "Sec-Ch-Ua-Platform")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    if !retried {
                        // Auth failed — stale cookies. Nuke cache + persistent tab, retry once
                        cookieManager.invalidateCache()
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
        } catch is CDPCookieManager.CDPError {
            return .noCDP
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
