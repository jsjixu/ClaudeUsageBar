import SwiftUI

struct PopoverView: View {
    let state: UsageState
    let lastRefresh: Date?
    let onRefresh: () -> Void
    let onQuit: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showSettings = false
    @State private var remoteURL: String = UsageAPI.remoteURL ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if UsageAPI.isRemoteMode {
                    Text("REMOTE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue))
                } else {
                    Text("LOCAL")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green))
                }
            }
            .padding(.bottom, 4)

            switch state {
            case .loading:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }
            case .loaded(let usage):
                usageContent(usage)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            case .authNeeded:
                Label("Token expired — run `claude` to refresh", systemImage: "lock.fill")
                    .foregroundColor(.red)
            case .noAuth:
                VStack(alignment: .leading, spacing: 4) {
                    Label("No Claude Code credentials found", systemImage: "key.fill")
                        .foregroundColor(.orange)
                    Text("Install Claude Code CLI and run `claude` to log in")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .noCDP:
                Label("Legacy CDP mode — update app", systemImage: "xmark.circle.fill")
                    .foregroundColor(.gray)
            }

            Divider()

            // Launch at Login toggle
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "power")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: launchAtLogin) { _, newValue in
                LaunchAtLogin.setEnabled(newValue)
            }

            // Remote mode settings
            DisclosureGroup("Remote Mode", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect to another Mac running ClaudeUsageBar to avoid 429 rate limits.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("http://host:9876", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    HStack {
                        Button(remoteURL.isEmpty ? "Using Local" : "Save & Restart") {
                            UsageAPI.setRemoteURL(remoteURL.isEmpty ? nil : remoteURL)
                            // Relaunch app to apply mode change
                            let url = Bundle.main.bundleURL
                            let task = Process()
                            task.launchPath = "/usr/bin/open"
                            task.arguments = ["-a", url.path]
                            try? task.run()
                            NSApp.terminate(nil)
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)

                        if !remoteURL.isEmpty {
                            Button("Clear") {
                                remoteURL = ""
                                UsageAPI.setRemoteURL(nil)
                                let url = Bundle.main.bundleURL
                                let task = Process()
                                task.launchPath = "/usr/bin/open"
                                task.arguments = ["-a", url.path]
                                try? task.run()
                                NSApp.terminate(nil)
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)

            // Footer
            HStack {
                if let lastRefresh = lastRefresh {
                    Text("Updated \(timeAgo(lastRefresh))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button(action: onQuit) {
                    Label("Quit", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func usageContent(_ usage: UsageResponse) -> some View {
        if let session = usage.fiveHour {
            usageRow(
                title: "Session (5h)",
                icon: "bolt.fill",
                utilization: session.utilization ?? 0,
                resetTime: session.timeUntilReset
            )
        }
        if let weekly = usage.sevenDay {
            usageRow(
                title: "Weekly (7d)",
                icon: "calendar",
                utilization: weekly.utilization ?? 0,
                resetTime: weekly.timeUntilReset
            )
        }
        if let sonnet = usage.sevenDaySonnet, let util = sonnet.utilization, util > 0 {
            usageRow(
                title: "Sonnet (7d)",
                icon: "sparkle",
                utilization: util,
                resetTime: sonnet.timeUntilReset
            )
        }
        if let opus = usage.sevenDayOpus, let util = opus.utilization, util > 0 {
            usageRow(
                title: "Opus (7d)",
                icon: "star.fill",
                utilization: util,
                resetTime: opus.timeUntilReset
            )
        }
    }

    private func usageRow(title: String, icon: String, utilization: Double, resetTime: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(colorForUtilization(utilization))
                    .frame(width: 16)
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundColor(colorForUtilization(utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(gradientForUtilization(utilization))
                        .frame(width: geo.size.width * min(utilization / 100.0, 1.0), height: 8)
                }
            }
            .frame(height: 8)
            HStack {
                Spacer()
                Text("Resets in \(resetTime)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func colorForUtilization(_ util: Double) -> Color {
        if util < 50 { return .green }
        if util < 80 { return .orange }
        return .red
    }

    private func gradientForUtilization(_ util: Double) -> LinearGradient {
        let color = colorForUtilization(util)
        return LinearGradient(
            colors: [color.opacity(0.7), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
