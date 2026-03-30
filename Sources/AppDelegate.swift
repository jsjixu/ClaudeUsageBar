import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?
    private let api = UsageAPI()

    private var currentState: UsageState = .loading
    private var lastRefresh: Date?
    private var lastUsage: UsageResponse?
    private var usageServer: UsageServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

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
        popover.contentSize = NSSize(width: 320, height: 340)
        updatePopoverContent()

        // Start embedded HTTP server in local mode (serves cache to remote clients)
        if !UsageAPI.isRemoteMode {
            let server = UsageServer()
            server.start()
            self.usageServer = server
        }

        // Initial fetch
        Task { await refresh() }

        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
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
            if case .loaded(let usage) = result {
                self.lastUsage = usage
                self.lastRefresh = Date()
                // Feed cache to embedded server
                self.usageServer?.updateCache(usage)
            }
            self.updateMenuBarText()
            self.updatePopoverContent()
            self.adjustRefreshRate(for: result)
        }
    }

    /// Speed up refresh when in error state, slow down when healthy
    private func adjustRefreshRate(for state: UsageState) {
        let interval: TimeInterval
        switch state {
        case .loaded:
            interval = 300  // 5 min when healthy
        case .authNeeded, .noAuth, .error, .noCDP:
            interval = 30   // 30s when errored — auto-recover faster
        case .loading:
            return
        }

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
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                state: state,
                lastRefresh: refresh,
                onRefresh: { [weak self] in
                    Task { await self?.refresh() }
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
    }
}
