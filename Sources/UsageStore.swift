import Foundation
import SQLite3

struct DeltaRecord {
    let date: String      // "yyyy-MM-dd"
    let hour: Int         // 0-23
    let delta: Double     // max - min utilization in this hour (≥ 0)
    let peakUtil: Double  // max utilization seen in this hour
}

final class UsageStore {
    static let shared = UsageStore()
    private var db: OpaquePointer?

    private init() {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }

        let dir = base.appendingPathComponent("ClaudeUsageBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("usage.sqlite").path

        guard sqlite3_open(path, &db) == SQLITE_OK else { return }

        let ddl = """
            CREATE TABLE IF NOT EXISTS snapshots (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                ts       REAL    NOT NULL,
                util5h   REAL,
                util7d   REAL
            );
            CREATE INDEX IF NOT EXISTS snapshots_ts ON snapshots(ts);
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Write

    func record(_ usage: UsageResponse) {
        let sql = "INSERT INTO snapshots (ts, util5h, util7d) VALUES (?,?,?)"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, Date().timeIntervalSince1970)
        bindOptional(s, 2, usage.fiveHour?.utilization)
        bindOptional(s, 3, usage.sevenDay?.utilization)
        sqlite3_step(s)
    }

    private func bindOptional(_ s: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(s, idx, v) } else { sqlite3_bind_null(s, idx) }
    }

    // MARK: - Read: heatmap data

    /// Returns one DeltaRecord per (date, hour) cell for the last `days` days.
    /// delta = max_util - min_util within that hour (proxy for activity).
    func deltaRecords(days: Int) -> [DeltaRecord] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let sql = """
            SELECT ts, util5h FROM snapshots
            WHERE ts >= ? AND util5h IS NOT NULL
            ORDER BY ts
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, cutoff)

        let cal = Calendar.current
        let fmt = iso8601DayFormatter()

        var groups: [String: (lo: Double, hi: Double)] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let ts   = sqlite3_column_double(s, 0)
            let util = sqlite3_column_double(s, 1)
            let date = Date(timeIntervalSince1970: ts)
            let hour = cal.component(.hour, from: date)
            let key  = "\(fmt.string(from: date))|\(hour)"
            if let g = groups[key] {
                groups[key] = (lo: min(g.lo, util), hi: max(g.hi, util))
            } else {
                groups[key] = (lo: util, hi: util)
            }
        }

        return groups.compactMap { key, g -> DeltaRecord? in
            let p = key.split(separator: "|")
            guard p.count == 2, let h = Int(p[1]) else { return nil }
            return DeltaRecord(
                date: String(p[0]), hour: h,
                delta: max(0, g.hi - g.lo), peakUtil: g.hi
            )
        }.sorted {
            $0.date == $1.date ? $0.hour < $1.hour : $0.date < $1.date
        }
    }

    // MARK: - Read: stat card helpers

    /// Average sevenDay utilization per week for the last `weeks` weeks (oldest first).
    func weeklyUtilizations(weeks: Int = 4) -> [Double] {
        var results: [Double] = []
        for w in (0..<weeks).reversed() {
            let end   = Date().addingTimeInterval(-Double(w) * 7 * 86400).timeIntervalSince1970
            let start = Date().addingTimeInterval(-Double(w + 1) * 7 * 86400).timeIntervalSince1970
            let sql = "SELECT AVG(util7d) FROM snapshots WHERE ts >= ? AND ts < ? AND util7d IS NOT NULL"
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { continue }
            sqlite3_bind_double(s, 1, start)
            sqlite3_bind_double(s, 2, end)
            if sqlite3_step(s) == SQLITE_ROW, sqlite3_column_type(s, 0) != SQLITE_NULL {
                results.append(sqlite3_column_double(s, 0))
            }
            sqlite3_finalize(s)
        }
        return results
    }

    /// Number of snapshots where the 5-hour bucket hit ≥ 80% in the past `days` days.
    func capsHit(days: Int = 7) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let sql = "SELECT COUNT(*) FROM snapshots WHERE ts >= ? AND util5h >= 80"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, cutoff)
        guard sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(s, 0))
    }

    // MARK: - Helpers

    private func iso8601DayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }
}
