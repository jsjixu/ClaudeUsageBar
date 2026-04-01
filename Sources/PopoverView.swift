import SwiftUI

struct PopoverView: View {
    let state: UsageState
    let lastRefresh: Date?
    let onRefresh: () -> Void
    let onQuit: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)

            // Tab bar
            Picker("", selection: $selectedTab) {
                Text("Usage").tag(0)
                Text("Stats").tag(1)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            if selectedTab == 1 {
                ScrollView {
                    StatsView()
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            } else {

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
            case .rateLimited(let retryAfter):
                Label("Rate limited — retrying in \(Int(retryAfter))s", systemImage: "hourglass")
                    .foregroundColor(.orange)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            case .authNeeded:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Claude Code 登录已过期", systemImage: "lock.fill")
                        .foregroundColor(.red)
                    Button(action: { openClaudeCode() }) {
                        Label("Open Claude Code", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Text("点击上方按钮，在弹出的终端中完成登录。\n登录成功后本 app 会自动恢复。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .noAuth:
                VStack(alignment: .leading, spacing: 8) {
                    if isClaudeCodeInstalled() {
                        Label("Claude Code 凭证已失效", systemImage: "key.fill")
                            .foregroundColor(.orange)
                        Button(action: { openClaudeCode() }) {
                            Label("Open Claude Code", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        Text("点击上方按钮，在弹出的终端中完成登录。\n登录成功后本 app 会自动恢复。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Label("未找到 Claude Code", systemImage: "key.fill")
                            .foregroundColor(.orange)
                        Button(action: { openClaudeCodeInstall() }) {
                            Label("Install Claude Code", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        Text("安装并登录 Claude Code 后，本 app 会自动连接。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            case .noCDP:
                Label("Legacy CDP mode — update app", systemImage: "xmark.circle.fill")
                    .foregroundColor(.gray)
            }

            } // end else (selectedTab == 0)

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
                        .fill(Color.primary.opacity(0.15))
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

    private func openClaudeCode() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func openClaudeCodeInstall() {
        if let url = URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isClaudeCodeInstalled() -> Bool {
        let paths = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        // Also check if ~/.claude directory exists (user has logged in before)
        let claudeDir = NSString(string: "~/.claude").expandingTildeInPath
        return FileManager.default.fileExists(atPath: claudeDir)
    }
}
