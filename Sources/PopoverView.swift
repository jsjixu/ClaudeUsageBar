import SwiftUI

struct PopoverView: View {
    let state: UsageState
    let lastRefresh: Date?
    let onRefresh: () -> Void
    let onQuit: () -> Void
    let onSettings: () -> Void

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
                Label("Login needed — open claude.ai in Chrome", systemImage: "lock.fill")
                    .foregroundColor(.red)
            case .noCDP:
                let host = CDPCookieManager.cdpHost
                let port = CDPCookieManager.cdpPort
                Label("Chrome CDP not available (\(host):\(port))", systemImage: "xmark.circle.fill")
                    .foregroundColor(.gray)
            }

            Divider()

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
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
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
