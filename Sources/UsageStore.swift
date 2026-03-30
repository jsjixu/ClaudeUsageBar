import Foundation
import SQLite3

struct UsageRecord: Sendable {
    let timestamp: Date
    let fiveHourUtil: Double
    let sevenDayUtil: Double
    let sonnetUtil: Double
    let opusUtil: Double
}

struct DeltaRecord: Sendable {
    let timestamp: Date
    let fiveHourDelta: Double
    let sevenDayDelta: Double
    let sonnetDelta: Double
    let opusDelta: Double
}

final class UsageStore {
    private static let createTableSQL = """
    CREATE TABLE IF NOT EXISTS usage_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL,
      five_hour_util REAL,
      seven_day_util REAL,
      sonnet_util REAL,
      opus_util REAL
    );
    """

    private var db: OpaquePointer?
    private let timestampFormatter: ISO8601DateFormatter
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.timestampFormatter = formatter

        do {
            let dbURL = try Self.databaseURL()
            var handle: OpaquePointer?
            if sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
                if let cString = sqlite3_errmsg(handle) {
                    print("UsageStore open error: \(String(cString: cString))")
                }
                sqlite3_close(handle)
                return
            }
            self.db = handle

            if sqlite3_exec(handle, Self.createTableSQL, nil, nil, nil) != SQLITE_OK {
                if let cString = sqlite3_errmsg(handle) {
                    print("UsageStore schema error: \(String(cString: cString))")
                }
            }
        } catch {
            print("UsageStore init error: \(error.localizedDescription)")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func insert(usage: UsageResponse) {
        guard let db else { return }
        let sql = """
        INSERT INTO usage_log (timestamp, five_hour_util, seven_day_util, sonnet_util, opus_util)
        VALUES (?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let cString = sqlite3_errmsg(db) {
                print("UsageStore insert prepare error: \(String(cString: cString))")
            }
            return
        }
        defer { sqlite3_finalize(statement) }

        let timestamp = timestampFormatter.string(from: Date())
        sqlite3_bind_text(statement, 1, timestamp, -1, sqliteTransient)

        bindOptionalDouble(usage.fiveHour?.utilization, index: 2, statement: statement)
        bindOptionalDouble(usage.sevenDay?.utilization, index: 3, statement: statement)
        bindOptionalDouble(usage.sevenDaySonnet?.utilization, index: 4, statement: statement)
        bindOptionalDouble(usage.sevenDayOpus?.utilization, index: 5, statement: statement)

        if sqlite3_step(statement) != SQLITE_DONE, let cString = sqlite3_errmsg(db) {
            print("UsageStore insert step error: \(String(cString: cString))")
        }
    }

    func query(days: Int) -> [UsageRecord] {
        guard days > 0, let db else { return [] }
        let sql = """
        SELECT
          timestamp,
          COALESCE(five_hour_util, 0),
          COALESCE(seven_day_util, 0),
          COALESCE(sonnet_util, 0),
          COALESCE(opus_util, 0)
        FROM usage_log
        WHERE timestamp >= ?
        ORDER BY timestamp ASC;
        """
        let cutoff = timestampFormatter.string(from: Date().addingTimeInterval(-Double(days) * 86_400))

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let cString = sqlite3_errmsg(db) {
                print("UsageStore query prepare error: \(String(cString: cString))")
            }
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, cutoff, -1, sqliteTransient)

        var results: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawTimestamp = sqlite3_column_text(statement, 0) else { continue }
            let timestampString = String(cString: rawTimestamp)
            guard let timestamp = parseTimestamp(timestampString) else { continue }

            let record = UsageRecord(
                timestamp: timestamp,
                fiveHourUtil: sqlite3_column_double(statement, 1),
                sevenDayUtil: sqlite3_column_double(statement, 2),
                sonnetUtil: sqlite3_column_double(statement, 3),
                opusUtil: sqlite3_column_double(statement, 4)
            )
            results.append(record)
        }
        return results
    }

    func deltaRecords(days: Int) -> [DeltaRecord] {
        let records = query(days: days)
        guard records.count > 1 else { return [] }

        var deltas: [DeltaRecord] = []
        deltas.reserveCapacity(records.count - 1)

        for index in 1..<records.count {
            let previous = records[index - 1]
            let current = records[index]
            deltas.append(
                DeltaRecord(
                    timestamp: current.timestamp,
                    fiveHourDelta: max(0, current.fiveHourUtil - previous.fiveHourUtil),
                    sevenDayDelta: max(0, current.sevenDayUtil - previous.sevenDayUtil),
                    sonnetDelta: max(0, current.sonnetUtil - previous.sonnetUtil),
                    opusDelta: max(0, current.opusUtil - previous.opusUtil)
                )
            )
        }

        return deltas
    }

    private static func databaseURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "UsageStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Application Support directory"])
        }
        let directory = base.appendingPathComponent("ClaudeUsageBar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.db")
    }

    private func bindOptionalDouble(_ value: Double?, index: Int32, statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func parseTimestamp(_ text: String) -> Date? {
        if let date = timestampFormatter.date(from: text) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: text)
    }
}
