import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?
    private var credentialsWatcher: DispatchSourceFileSystemObject?
    private var loginPollTimer: Timer?
    private let api = UsageAPI()

    private var currentState: UsageState = .loading
    private var lastRefresh: Date?
    private var lastUsage: UsageResponse?

    /// Global throttle: minimum seconds between consecutive API calls.
    /// Prevents credential watcher, timer, and manual refresh from piling up.
    private let minimumRefreshInterval: TimeInterval = 120  // 2 minutes
    private var lastAPICallTime: Date?
    private var isRefreshing = false
    /// Fingerprint of credentials at last watcher trigger — avoids spurious refreshes
    private var lastWatcherFingerprint: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Add Edit menu so Cmd+C/V/X/A work in text fields (SwiftUI popover bug)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editMenuItem)

        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarText()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover.behavior = .transient
        updatePopoverContent()

        // Initial fetch — delay 10s to avoid IP-level rate limits after rapid restarts
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await refresh()
        }

        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }

        startCredentialsWatcher()
    }

    private func startCredentialsWatcher() {
        let dir = NSString(string: "~/.claude").expandingTildeInPath
        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // Debounce 5s for file writes to settle (was 2s — too aggressive)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self = self else { return }
                // Only trigger refresh if credentials ACTUALLY changed
                let currentFP = self.credentialsFingerprint()
                if currentFP == self.lastWatcherFingerprint {
                    return  // Not a credential change, skip
                }
                self.lastWatcherFingerprint = currentFP
                NSLog("[CredWatch] Credentials changed — triggering refresh")
                Task { await self.refresh() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        credentialsWatcher = source
        // Seed initial fingerprint
        lastWatcherFingerprint = credentialsFingerprint()
    }

    /// Fast fingerprint over credential files (not full content, just mtime+size)
    private func credentialsFingerprint() -> String {
        var parts: [String] = []
        let paths = [
            NSString(string: "~/.claude/.credentials.json").expandingTildeInPath,
            NSString(string: "~/.claude/credentials.json").expandingTildeInPath
        ]
        for path in paths {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? Int) ?? 0
                parts.append("\(path):\(mtime):\(size)")
            }
        }
        // Also check Keychain fingerprint
        let keychainFP = keychainDataHash()
        parts.append("kc:\(keychainFP)")
        return parts.joined(separator: "|")
    }

    private func keychainDataHash() -> UInt64 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return 0 }
        var hash: UInt64 = 5381
        for byte in data { hash = hash &* 31 &+ UInt64(byte) }
        return hash
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refresh(force: Bool = false) async {
        // Global throttle — prevent multiple sources from piling up API calls
        if !force, let lastCall = lastAPICallTime {
            let elapsed = Date().timeIntervalSince(lastCall)
            if elapsed < minimumRefreshInterval {
                NSLog("[Refresh] Throttled — %.0fs since last call (min %.0fs)", elapsed, minimumRefreshInterval)
                return
            }
        }

        // Prevent concurrent refreshes
        guard !isRefreshing else {
            NSLog("[Refresh] Already refreshing, skipping")
            return
        }
        isRefreshing = true
        lastAPICallTime = Date()

        let result = await api.fetchUsage()
        isRefreshing = false

        await MainActor.run {
            self.currentState = result
            switch result {
            case .loaded(let usage):
                self.lastUsage = usage
                self.lastRefresh = Date()
                // Persist snapshot for history/heatmap
                UsageStore.shared.record(usage)
                // Stop login poll if running — we got data
                self.loginPollTimer?.invalidate()
                self.loginPollTimer = nil
            default:
                break
            }
            self.updateMenuBarText()
            self.updatePopoverContent()
            self.adjustRefreshRate(for: result)
        }
    }

    /// Start polling for credentials after user clicks login button
    func startLoginPoll() {
        loginPollTimer?.invalidate()
        var attempts = 0
        loginPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            attempts += 1
            if attempts > 30 { timer.invalidate(); return }  // 60s timeout
            if self?.api.oauthManager.hasValidToken() == true {
                timer.invalidate()
                self?.loginPollTimer = nil
                Task { await self?.refresh() }
            }
        }
    }

    /// Adjust refresh rate — delegates interval decision to FailureGate (single source of truth)
    private func adjustRefreshRate(for state: UsageState) {
        if case .loading = state { return }
        let interval = api.gate.suggestedInterval

        if let timer = refreshTimer, timer.timeInterval == interval { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private func updateMenuBarText() {
        guard let button = statusItem.button else { return }

        switch currentState {
        case .loading:
            button.title = "⏳ ..."
        case .loaded(let usage):
            let session = Int(usage.fiveHour?.utilization ?? 0)
            let weekly = Int(usage.sevenDay?.utilization ?? 0)

            let maxUtil = max(usage.fiveHour?.utilization ?? 0, usage.sevenDay?.utilization ?? 0)
            let color: NSColor
            if maxUtil < 50 {
                color = .systemGreen
            } else if maxUtil < 80 {
                color = .systemOrange
            } else {
                color = .systemRed
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]
            button.attributedTitle = NSAttributedString(string: "⚡\(session)% 📅\(weekly)%", attributes: attrs)
        case .rateLimited:
            button.title = "⏳ 429"
        case .error:
            button.title = "⚠️ Error"
        case .authNeeded:
            button.title = "🔒 Auth"
        case .noAuth:
            button.title = "🔑 No Key"
        case .noCDP:
            button.title = "⛔ CDP"
        }
    }

    private func updatePopoverContent() {
        let state = self.currentState
        let refresh = self.lastRefresh
        let hostingController = NSHostingController(
            rootView: PopoverView(
                state: state,
                lastRefresh: refresh,
                onRefresh: { [weak self] in
                    Task { await self?.refresh(force: true) }  // Manual refresh bypasses throttle
                },
                onQuit: {
                    NSApp.terminate(nil)
                },
                onLoginClicked: { [weak self] in
                    self?.startLoginPoll()
                }
            )
        )
        // Let SwiftUI calculate the intrinsic content size
        let fittingSize = hostingController.sizeThatFits(in: NSSize(width: 320, height: 10000))
        popover.contentSize = NSSize(width: 320, height: min(fittingSize.height, 500))
        popover.contentViewController = hostingController
    }
}
