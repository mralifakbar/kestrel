import Foundation
import SQLite3

public struct HistoryPoint: Hashable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var value: Double
}

public struct HistoryApp: Hashable, Identifiable {
    public var id: String
    public var name: String
    public var avgCPU: Double
    public var maxMemory: Double
}

public final class HistoryStore {
    public static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kestrel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite").path
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "kestrel.history")
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String = HistoryStore.defaultPath, readOnly: Bool = false) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK { db = nil; return }
        sqlite3_busy_timeout(db, 3000)
        if !readOnly {
            exec("PRAGMA journal_mode=WAL;")
            exec("CREATE TABLE IF NOT EXISTS metric (ts INTEGER NOT NULL, key TEXT NOT NULL, value REAL NOT NULL);")
            exec("CREATE INDEX IF NOT EXISTS metric_key_ts ON metric(key, ts);")
            exec("CREATE TABLE IF NOT EXISTS app (ts INTEGER NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL, cpu REAL NOT NULL, mem REAL NOT NULL);")
            exec("CREATE INDEX IF NOT EXISTS app_app_ts ON app(app, ts);")
            exec("CREATE INDEX IF NOT EXISTS app_ts ON app(ts);")
        }
    }

    deinit { sqlite3_close(db) }

    public var isOpen: Bool { db != nil }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    public func record(metrics: [String: Double], apps: [AppUsage], at date: Date = Date()) {
        guard db != nil else { return }
        let ts = Int64(date.timeIntervalSince1970)
        queue.async { [self] in
            exec("BEGIN;")
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO metric (ts, key, value) VALUES (?, ?, ?)", -1, &s, nil)
            for (k, v) in metrics where v.isFinite {
                sqlite3_bind_int64(s, 1, ts); sqlite3_bind_text(s, 2, k, -1, SQLITE_TRANSIENT); sqlite3_bind_double(s, 3, v)
                sqlite3_step(s); sqlite3_reset(s)
            }
            sqlite3_finalize(s)
            sqlite3_prepare_v2(db, "INSERT INTO app (ts, app, name, cpu, mem) VALUES (?, ?, ?, ?, ?)", -1, &s, nil)
            for a in apps {
                sqlite3_bind_int64(s, 1, ts); sqlite3_bind_text(s, 2, a.id, -1, SQLITE_TRANSIENT); sqlite3_bind_text(s, 3, a.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(s, 4, a.cpu); sqlite3_bind_double(s, 5, Double(a.memory))
                sqlite3_step(s); sqlite3_reset(s)
            }
            sqlite3_finalize(s)
            exec("COMMIT;")
        }
    }

    public func prune(retentionDays: Int) {
        let cutoff = Int64(Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970)
        queue.async { [self] in
            exec("DELETE FROM metric WHERE ts < \(cutoff);")
            exec("DELETE FROM app WHERE ts < \(cutoff);")
            exec("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    private func bucketSize(since: Date, points: Int) -> Int64 {
        max(60, Int64(Date().timeIntervalSince(since)) / Int64(max(points, 1)))
    }

    public func series(_ key: String, since: Date, points: Int = 240, aggregate: String = "AVG") -> [HistoryPoint] {
        guard db != nil else { return [] }
        let b = bucketSize(since: since, points: points)
        let fn = aggregate == "MAX" ? "MAX" : "AVG"
        return queue.sync {
            var s: OpaquePointer?
            var out: [HistoryPoint] = []
            sqlite3_prepare_v2(db, "SELECT (ts / \(b)) * \(b) AS t, \(fn)(value) FROM metric WHERE key = ? AND ts >= ? GROUP BY t ORDER BY t", -1, &s, nil)
            sqlite3_bind_text(s, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(s, 2, Int64(since.timeIntervalSince1970))
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(HistoryPoint(date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0))), value: sqlite3_column_double(s, 1)))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    public func appSeries(_ app: String, since: Date, points: Int = 240) -> (cpu: [HistoryPoint], mem: [HistoryPoint]) {
        guard db != nil else { return ([], []) }
        let b = bucketSize(since: since, points: points)
        return queue.sync {
            var s: OpaquePointer?
            var cpu: [HistoryPoint] = [], mem: [HistoryPoint] = []
            sqlite3_prepare_v2(db, "SELECT (ts / \(b)) * \(b) AS t, AVG(cpu), MAX(mem) FROM app WHERE app = ? AND ts >= ? GROUP BY t ORDER BY t", -1, &s, nil)
            sqlite3_bind_text(s, 1, app, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(s, 2, Int64(since.timeIntervalSince1970))
            while sqlite3_step(s) == SQLITE_ROW {
                let d = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)))
                cpu.append(HistoryPoint(date: d, value: sqlite3_column_double(s, 1)))
                mem.append(HistoryPoint(date: d, value: sqlite3_column_double(s, 2)))
            }
            sqlite3_finalize(s)
            return (cpu, mem)
        }
    }

    public func topApps(since: Date, limit: Int = 25) -> [HistoryApp] {
        guard db != nil else { return [] }
        return queue.sync {
            var s: OpaquePointer?
            var out: [HistoryApp] = []
            let samples = "(SELECT COUNT(DISTINCT ts) FROM metric WHERE key='cpu' AND ts >= ?1)"
            sqlite3_prepare_v2(db, "SELECT app, MAX(name), SUM(cpu) / MAX(1, \(samples)), MAX(mem) FROM app WHERE ts >= ?1 GROUP BY app ORDER BY 3 DESC LIMIT \(limit)", -1, &s, nil)
            sqlite3_bind_int64(s, 1, Int64(since.timeIntervalSince1970))
            while sqlite3_step(s) == SQLITE_ROW {
                out.append(HistoryApp(id: String(cString: sqlite3_column_text(s, 0)), name: String(cString: sqlite3_column_text(s, 1)),
                                      avgCPU: sqlite3_column_double(s, 2), maxMemory: sqlite3_column_double(s, 3)))
            }
            sqlite3_finalize(s)
            return out
        }
    }

    public var fileSize: UInt64 {
        let p = HistoryStore.defaultPath
        return ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64) ?? 0) + ((try? FileManager.default.attributesOfItem(atPath: p + "-wal")[.size] as? UInt64) ?? 0)
    }
}
