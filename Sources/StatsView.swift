import SwiftUI

// MARK: - Top-level Stats view

struct StatsView: View {
    @State private var records: [DeltaRecord] = []
    @State private var weeklyUtils: [Double] = []
    @State private var capsHit7d: Int = 0
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if records.isEmpty {
                emptyState
            } else {
                statsContent
            }
        }
        .onAppear { loadData() }
    }

    private func loadData() {
        records      = UsageStore.shared.deltaRecords(days: 30)
        weeklyUtils  = UsageStore.shared.weeklyUtilizations(weeks: 4)
        capsHit7d    = UsageStore.shared.capsHit(days: 7)
        loaded       = true
    }

    @ViewBuilder
    private var statsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummaryStatsSection(records: records)
            Divider()
            StatCardsSection(records: records, weeklyUtils: weeklyUtils, capsHit7d: capsHit7d)
            Divider()
            BarChartSection(records: records)
            Divider()
            HeatmapSection(records: records)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("No history yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Usage history accumulates as Claude Code runs. Check back after some activity.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - Heatmap

struct HeatmapSection: View {
    let records: [DeltaRecord]

    private let cellSize: CGFloat = 8
    private let cellGap: CGFloat  = 1

    private var grid: [String: [Int: Double]] {
        var g: [String: [Int: Double]] = [:]
        for r in records { g[r.date, default: [:]][r.hour] = r.delta }
        return g
    }

    private var days: [String] {
        let fmt = dayFormatter()
        return (0..<30).reversed().compactMap { offset in
            Calendar.current.date(byAdding: .day, value: -offset, to: Date()).map { fmt.string(from: $0) }
        }
    }

    private var maxDelta: Double { max(records.map(\.delta).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity — Last 30 Days")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)

            HStack(alignment: .top, spacing: 0) {
                // Y-axis: hour labels every 6h
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Group {
                            if hour % 6 == 0 {
                                Text(String(format: "%02d", hour))
                                    .font(.system(size: 6, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 18, height: cellSize + cellGap, alignment: .leading)
                            } else {
                                Color.clear.frame(width: 18, height: cellSize + cellGap)
                            }
                        }
                    }
                    Color.clear.frame(width: 18, height: 14) // date label row placeholder
                }

                // Grid: columns = days, rows = hours
                HStack(spacing: cellGap) {
                    ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                        VStack(spacing: cellGap) {
                            ForEach(0..<24, id: \.self) { hour in
                                let delta = grid[day]?[hour] ?? 0
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(heatColor(delta: delta))
                                    .frame(width: cellSize, height: cellSize)
                            }
                            // Date label every 7 columns
                            Group {
                                if idx % 7 == 0 {
                                    Text(shortDate(day))
                                        .font(.system(size: 6))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: cellSize, height: 14, alignment: .leading)
                                } else {
                                    Color.clear.frame(width: cellSize, height: 14)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func heatColor(delta: Double) -> Color {
        guard delta > 0 else { return Color.primary.opacity(0.07) }
        let t = min(delta / maxDelta, 1.0)
        // Light green → dark green (semantic, dark mode friendly)
        return Color.green.opacity(0.2 + t * 0.8)
    }

    private func shortDate(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return "" }
        return "\(m)/\(d)"
    }

    private func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone.current
        return f
    }
}

// MARK: - Summary stats row

struct SummaryStatsSection: View {
    let records: [DeltaRecord]

    private var todayStr: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone.current
        return f.string(from: Date())
    }

    private var activeHoursToday: Int {
        records.filter { $0.date == todayStr && $0.delta > 0 }.count
    }

    private var peakHour: String {
        guard let top = records.max(by: { $0.delta < $1.delta }) else { return "—" }
        return String(format: "%02d:00", top.hour)
    }

    private var weekComparison: (value: String, color: Color) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone.current
        let cal  = Calendar.current
        let now  = Date()
        let wk1  = cal.date(byAdding: .day, value: -7,  to: now)!
        let wk2  = cal.date(byAdding: .day, value: -14, to: now)!

        var thisW = 0.0, lastW = 0.0
        for r in records {
            guard let d = f.date(from: r.date) else { continue }
            if d >= wk1 { thisW += r.delta } else if d >= wk2 { lastW += r.delta }
        }
        if lastW > 0 {
            let pct = (thisW - lastW) / lastW * 100
            let s   = "\(pct >= 0 ? "+" : "")\(Int(pct))%"
            return (s, pct >= 0 ? .green : .orange)
        }
        return thisW > 0 ? ("New", .green) : ("—", .secondary)
    }

    var body: some View {
        HStack(spacing: 0) {
            chip(icon: "clock.fill",         label: "Active today",  value: "\(activeHoursToday)h")
            chip(icon: "star.fill",          label: "Peak hour",     value: peakHour)
            let wc = weekComparison
            chipColored(icon: "arrow.up.arrow.down", label: "vs last week",
                        value: wc.value, color: wc.color)
        }
    }

    private func chip(icon: String, label: String, value: String) -> some View {
        chipColored(icon: icon, label: label, value: value, color: .primary)
    }

    private func chipColored(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundColor(.accentColor)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 7-day bar chart

struct BarChartSection: View {
    let records: [DeltaRecord]

    private struct DayBar: Identifiable {
        let id: String
        let label: String
        let value: Double
        let isToday: Bool
    }

    private var bars: [DayBar] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale     = Locale(identifier: "en_US_POSIX")
        fmt.timeZone   = TimeZone.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE"
        let today = fmt.string(from: Date())
        var byDay: [String: Double] = [:]
        for r in records { byDay[r.date, default: 0] += r.delta }

        return (0..<7).reversed().compactMap { offset -> DayBar? in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let ds    = fmt.string(from: date)
            let label = offset == 0 ? "Today" : dayFmt.string(from: date)
            return DayBar(id: ds, label: label, value: byDay[ds] ?? 0, isToday: ds == today)
        }
    }

    private var maxValue: Double { max(bars.map(\.value).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("7-Day Activity")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(bars) { bar in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar.isToday ? Color.accentColor : Color.green.opacity(0.65))
                            .frame(width: 30, height: max(3, 56 * bar.value / maxValue))
                        Text(bar.label)
                            .font(.system(size: 8))
                            .foregroundColor(bar.isToday ? .accentColor : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 72)
        }
    }
}

// MARK: - Stat cards

struct StatCardsSection: View {
    let records: [DeltaRecord]
    let weeklyUtils: [Double]
    let capsHit7d: Int

    private var planUtilAvg: Double {
        guard !weeklyUtils.isEmpty else { return 0 }
        return weeklyUtils.reduce(0, +) / Double(weeklyUtils.count)
    }

    private var mostActiveHour: String {
        var byHour: [Int: Double] = [:]
        for r in records { byHour[r.hour, default: 0] += r.delta }
        guard let (hour, _) = byHour.max(by: { $0.value < $1.value }) else { return "—" }
        return String(format: "%02d:00", hour)
    }

    private var dailyAvg30d: Double {
        let byDay = Dictionary(grouping: records, by: \.date)
        guard !byDay.isEmpty else { return 0 }
        let totals = byDay.values.map { recs in recs.reduce(0.0) { $0 + $1.delta } }
        return totals.reduce(0, +) / Double(totals.count)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                let pu = planUtilAvg
                card(icon: "gauge.medium",
                     title: "Plan util (4wk avg)",
                     value: String(format: "%.0f%%", pu),
                     color: pu < 50 ? .green : pu < 80 ? .orange : .red)
                card(icon: "exclamationmark.circle.fill",
                     title: "Caps hit (7d)",
                     value: "\(capsHit7d)",
                     color: capsHit7d == 0 ? .green : .orange)
            }
            HStack(spacing: 6) {
                card(icon: "clock.fill",
                     title: "Most active hour",
                     value: mostActiveHour,
                     color: .accentColor)
                card(icon: "chart.line.uptrend.xyaxis",
                     title: "Daily avg (30d)",
                     value: String(format: "%.1f%%", dailyAvg30d),
                     color: .accentColor)
            }
        }
    }

    private func card(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(8)
    }
}
