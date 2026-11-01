import Foundation
import SQLite3

public struct LimitWindow: Codable, Hashable, Identifiable {
    public var id: String { label }
    public var label: String
    public var used: Double                 // 0...1
    public var resetsAt: Date?
    public var windowSeconds: Double?
    public var detail: String?
    public var remaining: Double { max(0, 1 - used) }
    /// >1 means burning faster than the window allows.
    public var pace: Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let elapsed = 1 - resetsAt.timeIntervalSinceNow / windowSeconds
        guard elapsed > 0.02 else { return nil }
        return used / min(elapsed, 1)
    }
    public var paceText: String {
        guard let p = pace else { return "" }
        if p > 1.15 { return "Ahead of pace — may run out before reset" }
        if p < 0.85 { return "Under pace" }
        return "On pace"
    }
}

public struct ProviderLimits: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var plan: String?
    public var windows: [LimitWindow]
    public var error: String?
    public var updated: Date
}

public struct TokenUsage: Codable, Hashable, Identifiable {
    public var id: String { provider }
    public var provider: String
    public var today: Int
    public var week: Int
    public var outputToday: Int
    public var sessionsToday: Int
}

public enum UsageLimits {
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let isoPlain = ISO8601DateFormatter()
    static func date(_ s: String?) -> Date? { guard let s else { return nil }; return iso.date(from: s) ?? isoPlain.date(from: s) }

    static func get(_ url: String, headers: [String: String]) -> (Int, [String: Any]?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u, timeoutInterval: 15)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var json: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let data { json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return (status, json)
    }

    public static func fetchAll(providers: Set<String> = KestrelPrefs.enabledLimitProviders) -> [ProviderLimits] {
        var out: [ProviderLimits] = []
        if providers.contains("claude"), let c = claude() { out.append(c) }
        if providers.contains("codex"), let c = codex() { out.append(c) }
        if providers.contains("copilot"), let c = copilot() { out.append(c) }
        if providers.contains("cursor"), let c = cursor() { out.append(c) }
        return out
    }

    // Claude (Pro/Max subscription via Claude Code's OAuth login)
    static func claudeCredentials() -> (token: String, plan: String?)? {
        var raw = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw?.isEmpty ?? true { raw = try? String(contentsOfFile: "\(NSHomeDirectory())/.claude/.credentials.json", encoding: .utf8) }
        guard let raw, let d = raw.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let o = j["claudeAiOauth"] as? [String: Any], let token = o["accessToken"] as? String else { return nil }
        return (token, o["subscriptionType"] as? String)
    }

    public static func claude() -> ProviderLimits? {
        guard FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.claude") else { return nil }
        guard let cred = claudeCredentials() else {
            return ProviderLimits(id: "claude", name: "Claude", plan: nil, windows: [], error: "Sign in with `claude` (Pro/Max) to see limits", updated: Date())
        }
        let (status, j) = get("https://api.anthropic.com/api/oauth/usage", headers: ["Authorization": "Bearer \(cred.token)", "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"])
        guard status == 200, let j else {
            return ProviderLimits(id: "claude", name: "Claude", plan: cred.plan?.capitalized, windows: [], error: status == 401 ? "Session expired — run `claude` once to refresh" : "Couldn't reach Anthropic (\(status))", updated: Date())
        }
        let names: [(String, String, Double)] = [("five_hour", "Session (5h)", 5 * 3600), ("seven_day", "Week", 7 * 86400),
                                                  ("seven_day_opus", "Week · Opus", 7 * 86400), ("seven_day_sonnet", "Week · Sonnet", 7 * 86400),
                                                  ("seven_day_oauth_apps", "Week · Apps", 7 * 86400)]
        var windows: [LimitWindow] = []
        for (key, label, secs) in names {
            guard let w = j[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(LimitWindow(label: label, used: u / 100, resetsAt: date(w["resets_at"] as? String), windowSeconds: secs))
        }
        if let extra = j["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true, let u = (extra["utilization"] as? NSNumber)?.doubleValue {
            windows.append(LimitWindow(label: "Extra usage", used: u / 100, resetsAt: nil, windowSeconds: nil))
        }
        return ProviderLimits(id: "claude", name: "Claude", plan: cred.plan?.capitalized, windows: windows, error: nil, updated: Date())
    }

    // Codex: rate limits are written into the session logs.
    public static func codex() -> ProviderLimits? {
        let root = "\(NSHomeDirectory())/.codex/sessions"
        guard FileManager.default.fileExists(atPath: root), let newest = recentFiles(root, ext: "jsonl", days: 8).max(by: { $0.1 < $1.1 })?.0,
              let text = try? String(contentsOfFile: newest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let payload = j["payload"] as? [String: Any] ?? j
            guard let rl = payload["rate_limits"] as? [String: Any] ?? (payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            let ts = date(j["timestamp"] as? String) ?? Date()
            var windows: [LimitWindow] = []
            for (key, fallback) in [("primary", "Session"), ("secondary", "Week")] {
                guard let w = rl[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let mins = (w["window_minutes"] as? NSNumber)?.doubleValue
                var reset: Date?
                if let r = (w["resets_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: r) }
                else if let r = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { reset = ts.addingTimeInterval(r) }
                let label = mins.map { $0 <= 600 ? "Session (\(Int($0 / 60))h)" : $0 >= 10000 ? "Week" : fallback } ?? fallback
                windows.append(LimitWindow(label: label, used: used / 100, resetsAt: reset, windowSeconds: mins.map { $0 * 60 }))
            }
            return ProviderLimits(id: "codex", name: "Codex", plan: (rl["plan_type"] as? String)?.capitalized, windows: windows, error: nil, updated: ts)
        }
        return ProviderLimits(id: "codex", name: "Codex", plan: nil, windows: [], error: "No recent session with limit data", updated: Date())
    }

    // GitHub Copilot via the gh CLI token.
    public static func copilot() -> ProviderLimits? {
        guard let gh = Shell.which("gh"), let token = Shell.run(gh, ["auth", "token"], timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        let (status, j) = get("https://api.github.com/copilot_internal/user", headers: ["Authorization": "token \(token)", "Accept": "application/json", "Editor-Version": "vscode/1.99.0", "User-Agent": "Kestrel"])
        guard status == 200, let j else { return status == 404 ? nil : ProviderLimits(id: "copilot", name: "Copilot", plan: nil, windows: [], error: "Couldn't load Copilot quota (\(status))", updated: Date()) }
        let reset = (j["quota_reset_date"] as? String).flatMap { s -> Date? in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s) ?? date(s) }
        var windows: [LimitWindow] = []
        if let snaps = j["quota_snapshots"] as? [String: Any] {
            for (key, label) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
                guard let s = snaps[key] as? [String: Any], (s["unlimited"] as? Bool) != true, let pr = (s["percent_remaining"] as? NSNumber)?.doubleValue else { continue }
                let ent = (s["entitlement"] as? NSNumber)?.intValue
                let rem = (s["remaining"] as? NSNumber)?.intValue
                windows.append(LimitWindow(label: label, used: max(0, 1 - pr / 100), resetsAt: reset, windowSeconds: 30 * 86400,
                                           detail: ent.map { "\(rem ?? 0) of \($0) left" }))
            }
        }
        return ProviderLimits(id: "copilot", name: "Copilot", plan: (j["copilot_plan"] as? String)?.capitalized, windows: windows, error: windows.isEmpty ? "Unlimited plan" : nil, updated: Date())
    }

    // Cursor: token stored by the Cursor app.
    public static func cursor() -> ProviderLimits? {
        let path = "\(NSHomeDirectory())/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var token: String?
        if sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            token = String(cString: c)
        }
        sqlite3_finalize(stmt)
        guard let token, let sub = jwtSubject(token) else { return ProviderLimits(id: "cursor", name: "Cursor", plan: nil, windows: [], error: "Sign in to Cursor", updated: Date()) }
        let user = sub.split(separator: "|").last.map(String.init) ?? sub
        let (status, j) = get("https://cursor.com/api/usage?user=\(user)", headers: ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)"])
        guard status == 200, let j else { return ProviderLimits(id: "cursor", name: "Cursor", plan: nil, windows: [], error: "Couldn't load Cursor usage (\(status))", updated: Date()) }
        let start = date(j["startOfMonth"] as? String)
        var windows: [LimitWindow] = []
        for (k, v) in j.sorted(by: { $0.key < $1.key }) {
            guard let m = v as? [String: Any], let n = (m["numRequests"] as? NSNumber)?.doubleValue, let mx = (m["maxRequestUsage"] as? NSNumber)?.doubleValue, mx > 0 else { continue }
            windows.append(LimitWindow(label: k == "gpt-4" ? "Fast requests" : k, used: n / mx, resetsAt: start.map { Calendar.current.date(byAdding: .month, value: 1, to: $0)! },
                                       windowSeconds: 30 * 86400, detail: "\(Int(n)) of \(Int(mx))"))
        }
        return ProviderLimits(id: "cursor", name: "Cursor", plan: nil, windows: windows, error: windows.isEmpty ? "Usage-based plan" : nil, updated: Date())
    }

    static func jwtSubject(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["sub"] as? String
    }

    static func recentFiles(_ root: String, ext: String, days: Double) -> [(String, Date, Int)] {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        var out: [(String, Date, Int)] = []
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return out }
        for case let url as URL in e where url.pathExtension == ext {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), let m = v.contentModificationDate, m > cutoff else { continue }
            out.append((url.path, m, v.fileSize ?? 0))
        }
        return out
    }
}

/// Token counts from local session logs (Claude Code, Codex). Cached per file.
public final class TokenCounter {
    private struct Entry { var id: String; var ts: Date; var total: Int; var output: Int; var session: String }
    private var cache: [String: (Date, Int, [Entry])] = [:]
    public init() {}

    public func usage() -> [TokenUsage] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let week = cal.date(byAdding: .day, value: -6, to: today)!
        var out: [TokenUsage] = []
        for (provider, root, parser) in [("Claude Code", "\(NSHomeDirectory())/.claude/projects", parseClaude), ("Codex", "\(NSHomeDirectory())/.codex/sessions", parseCodex)] as [(String, String, (String) -> [Entry])] {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            var seen = Set<String>()
            var t = 0, w = 0, o = 0
            var sessions = Set<String>()
            let files = UsageLimits.recentFiles(root, ext: "jsonl", days: 8)
            for (path, mtime, size) in files {
                let entries: [Entry]
                if let c = cache[path], c.0 == mtime, c.1 == size { entries = c.2 }
                else { entries = parser(path); cache[path] = (mtime, size, entries) }
                for e in entries where e.ts >= week {
                    if !e.id.isEmpty { if seen.contains(e.id) { continue }; seen.insert(e.id) }
                    w += e.total
                    if e.ts >= today { t += e.total; o += e.output; sessions.insert(e.session) }
                }
            }
            let live = Set(files.map(\.0))
            cache = cache.filter { !$0.key.hasPrefix(root) || live.contains($0.key) }
            out.append(TokenUsage(provider: provider, today: t, week: w, outputToday: o, sessionsToday: sessions.count))
        }
        return out
    }

    private func parseClaude(_ path: String) -> [Entry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        let session = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for line in text.split(separator: "\n") where line.contains("\"usage\"") && line.contains("\"assistant\"") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = j["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let ts = UsageLimits.date(j["timestamp"] as? String) else { continue }
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            let output = n("output_tokens")
            let total = n("input_tokens") + output + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            let id = (msg["id"] as? String ?? "") + ":" + (j["requestId"] as? String ?? "")
            out.append(Entry(id: id, ts: ts, total: total, output: output, session: session))
        }
        return out
    }

    private func parseCodex(_ path: String) -> [Entry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        let session = URL(fileURLWithPath: path).lastPathComponent
        for line in text.split(separator: "\n") where line.contains("token_count") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = j["payload"] as? [String: Any], let info = p["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any], let ts = UsageLimits.date(j["timestamp"] as? String) else { continue }
            let total = (last["total_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (last["output_tokens"] as? NSNumber)?.intValue ?? 0
            out.append(Entry(id: "", ts: ts, total: total, output: output, session: session))
        }
        return out
    }
}
