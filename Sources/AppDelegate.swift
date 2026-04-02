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

        // Initial fetch
        Task { await refresh() }

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
            // Debounce 2s for file writes to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task { await self?.refresh() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        credentialsWatcher = source
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

    private func refresh() async {
        let result = await api.fetchUsage()
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
                    Task { await self?.refresh() }
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
