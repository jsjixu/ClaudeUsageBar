import Foundation

// MARK: - FailureGate

/// Tracks consecutive API failures and suggests retry intervals to prevent hammering.
class FailureGate {
    private struct CredentialFingerprint: Equatable {
        let modificationDate: Date
        let fileSize: Int
    }

    private(set) var consecutiveFailures: Int = 0
    private(set) var isTerminalAuthBlock: Bool = false
    private var terminalFingerprint: CredentialFingerprint? = nil
    private(set) var suggestedInterval: TimeInterval = 300

    func recordSuccess() {
        consecutiveFailures = 0
        isTerminalAuthBlock = false
        terminalFingerprint = nil
        suggestedInterval = 300
    }

    /// Mark a 401/403 terminal auth failure. Polls every 60s to detect credential changes.
    func recordAuthFailure() {
        isTerminalAuthBlock = true
        terminalFingerprint = currentFingerprint()
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
        // Exponential backoff: 5min base, doubling each failure after the first surfaced one
        // failure 2 → 5min, failure 3 → 10min, failure 4 → 20min ... cap at 6h
        let doublings = max(consecutiveFailures - 2, 0)
        suggestedInterval = min(300.0 * pow(2.0, Double(doublings)), 21600)
        return false
    }

    /// True if credentials file changed since terminal block was set (user re-authenticated).
    func credentialsChanged() -> Bool {
        guard isTerminalAuthBlock else { return false }
        return currentFingerprint() != terminalFingerprint
    }

    func clearTerminalBlock() {
        isTerminalAuthBlock = false
        terminalFingerprint = nil
        consecutiveFailures = 0
        suggestedInterval = 300
    }

    private func currentFingerprint() -> CredentialFingerprint? {
        let path = NSString(string: "~/.claude/.credentials.json").expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? Int else {
            return nil
        }
        return CredentialFingerprint(modificationDate: modDate, fileSize: fileSize)
    }
}

// MARK: - UsageAPI

class UsageAPI {
    private let oauthManager = OAuthManager()
    let gate = FailureGate()
    private var lastGoodUsage: UsageResponse?

    /// Fetch usage — if remoteURL is set, read from remote cache; otherwise query Anthropic directly.
    func fetchUsage() async -> UsageState {
        if let remoteURL = Self.remoteURL, !remoteURL.isEmpty {
            return await fetchFromRemote(remoteURL)
        }

        // Skip the API call if we're in a terminal auth block and credentials haven't changed
        if gate.isTerminalAuthBlock {
            if gate.credentialsChanged() {
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

    /// Raw TCP fetch that bypasses ATS entirely — just sends HTTP/1.1 over a plain socket.
    private func fetchFromRemote(_ urlString: String) async -> UsageState {
        // Normalize URL — append /usage if it looks like just a host:port
        let normalizedURL: String
        if urlString.hasSuffix("/usage") || urlString.hasSuffix("/usage/") {
            normalizedURL = urlString
        } else {
            let trimmed = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            normalizedURL = trimmed + "/usage"
        }

        // Parse host and port from URL
        guard let url = URL(string: normalizedURL) else {
            return .error("Invalid remote URL")
        }
        guard let host = url.host else { return .error("No host in URL") }
        let port = url.port ?? 80
        let path = url.path.isEmpty ? "/" : url.path

        do {
            let data = try await rawHTTPGet(host: host, port: UInt16(port), path: path)

            let decoder = JSONDecoder()
            let usage = try decoder.decode(UsageResponse.self, from: data)
            return .loaded(usage)
        } catch {
            return .error("Remote: \(error.localizedDescription)")
        }
    }

    /// Minimal HTTP/1.1 GET over raw TCP socket — completely bypasses ATS.
    private func rawHTTPGet(host: String, port: UInt16, path: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            var inputStream: InputStream?
            var outputStream: OutputStream?
            Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &inputStream, outputStream: &outputStream)

            guard let input = inputStream, let output = outputStream else {
                continuation.resume(throwing: NSError(domain: "UsageAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create streams to \(host):\(port)"]))
                return
            }

            input.open()
            output.open()

            // Send HTTP request
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            let requestData = Array(request.utf8)
            output.write(requestData, maxLength: requestData.count)

            // Read response
            var responseData = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            // Simple blocking read with timeout
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if input.hasBytesAvailable {
                    let bytesRead = input.read(buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        responseData.append(buffer, count: bytesRead)
                    } else if bytesRead == 0 {
                        break // EOF
                    } else {
                        break // Error
                    }
                } else if input.streamStatus == .atEnd || input.streamStatus == .closed || input.streamStatus == .error {
                    break
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            input.close()
            output.close()

            // Parse HTTP response — find body after \r\n\r\n
            guard let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) else {
                continuation.resume(throwing: NSError(domain: "UsageAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
                return
            }

            let body = responseData.subdata(in: headerEnd.upperBound..<responseData.endIndex)
            continuation.resume(returning: body)
        }
    }

    // MARK: - Local mode (server — direct Anthropic API)

    private func doFetch(retried: Bool) async -> UsageState {
        do {
            let token = try await oauthManager.getAccessToken()

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
        } catch is OAuthManager.OAuthError {
            return .noAuth
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
