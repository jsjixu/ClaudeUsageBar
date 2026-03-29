import Foundation

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

struct UsageBucket: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: String {
        guard let resetDate = resetDate else { return "Unknown" }
        let now = Date()
        if resetDate <= now { return "Resetting..." }
        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: resetDate)
        if let d = diff.day, d > 0 {
            return "\(d)d \(diff.hour ?? 0)h"
        }
        if let h = diff.hour, h > 0 {
            return "\(h)h \(diff.minute ?? 0)m"
        }
        return "\(diff.minute ?? 0)m"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
    }
}

enum UsageState {
    case loading
    case loaded(UsageResponse)
    case error(String)
    case authNeeded   // Token expired
    case noAuth       // No credentials found
    case noCDP        // Legacy — kept for compatibility but unused in OAuth mode
}
