import Foundation

public enum TempUnit: String, CaseIterable, Codable { case celsius, fahrenheit }
public enum RateUnit: String, CaseIterable, Codable { case bytes, bits }
public enum CPUScale: String, CaseIterable, Codable { case perCore, perMac }

/// Shared preferences between the app, the CLI and the MCP server.
public enum KestrelPrefs {
    public static let suiteName = "dev.kestrel.shared"
    public static var shared: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    public static var tempUnit: TempUnit {
        get { TempUnit(rawValue: shared.string(forKey: "tempUnit") ?? "") ?? .celsius }
        set { shared.set(newValue.rawValue, forKey: "tempUnit") }
    }
    public static var rateUnit: RateUnit {
        get { RateUnit(rawValue: shared.string(forKey: "rateUnit") ?? "") ?? .bytes }
        set { shared.set(newValue.rawValue, forKey: "rateUnit") }
    }
    public static var cpuScale: CPUScale {
        get { CPUScale(rawValue: shared.string(forKey: "cpuScale") ?? "") ?? .perCore }
        set { shared.set(newValue.rawValue, forKey: "cpuScale") }
    }
    public static var mcpEnabled: Bool {
        get { shared.bool(forKey: "mcpEnabled") }
        set { shared.set(newValue, forKey: "mcpEnabled") }
    }
    public static var limitsEnabled: Bool {
        get { shared.bool(forKey: "limitsEnabled") }
        set { shared.set(newValue, forKey: "limitsEnabled") }
    }
    public static var enabledLimitProviders: Set<String> {
        get { Set(shared.stringArray(forKey: "limitProviders") ?? ["claude", "codex", "copilot", "cursor"]) }
        set { shared.set(Array(newValue).sorted(), forKey: "limitProviders") }
    }
    public static var historyRetentionDays: Int {
        get { let v = shared.integer(forKey: "historyRetentionDays"); return v == 0 ? 30 : v }
        set { shared.set(newValue, forKey: "historyRetentionDays") }
    }
    public static var idleServerMinutes: Int {
        get { let v = shared.integer(forKey: "idleServerMinutes"); return v == 0 ? 30 : v }
        set { shared.set(newValue, forKey: "idleServerMinutes") }
    }
}

public enum KestrelVersion {
    /// Falls back to this when the CLI runs outside the app bundle.
    public static let string = "0.1.0"
}

public enum Fmt {
    public static func bytes(_ v: UInt64, decimals: Int = 1) -> String { bytes(Double(v), decimals: decimals) }

    public static func bytes(_ v: Double, decimals: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var x = max(0, v), i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return "\(Int(x)) B" }
        return String(format: "%.\(x >= 100 ? 0 : decimals)f %@", x, units[i])
    }

    public static func rate(_ bps: Double, unit: RateUnit = KestrelPrefs.rateUnit) -> String {
        switch unit {
        case .bytes: return bytes(bps) + "/s"
        case .bits:
            let units = ["b", "Kb", "Mb", "Gb", "Tb"]
            var x = max(0, bps * 8), i = 0
            while x >= 1000 && i < units.count - 1 { x /= 1000; i += 1 }
            return String(format: i == 0 ? "%.0f %@ps" : "%.1f %@ps", x, units[i])
        }
    }

    /// Short form used in the menu bar, e.g. "1.2M".
    public static func compactRate(_ bps: Double, unit: RateUnit = KestrelPrefs.rateUnit) -> String {
        let v = unit == .bits ? bps * 8 : bps
        let base: Double = unit == .bits ? 1000 : 1024
        let units = ["", "K", "M", "G", "T"]
        var x = max(0, v), i = 0
        while x >= base && i < units.count - 1 { x /= base; i += 1 }
        let suffix = unit == .bits ? "b" : "B"
        if i == 0 { return String(format: "%.0f%@", x, suffix) }
        return String(format: x >= 10 ? "%.0f%@" : "%.1f%@", x, units[i])
    }

    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", fraction * 100)
    }

    /// CPU percentage where 100 = one core. Respects the per-core / per-Mac preference.
    public static func cpu(_ percentOfCore: Double, cores: Int, scale: CPUScale = KestrelPrefs.cpuScale) -> String {
        let v = scale == .perCore ? percentOfCore : percentOfCore / Double(max(cores, 1))
        return String(format: v >= 10 ? "%.0f%%" : "%.1f%%", v)
    }

    public static func temp(_ c: Double, unit: TempUnit = KestrelPrefs.tempUnit) -> String {
        guard c > 0 else { return "–" }
        return unit == .celsius ? String(format: "%.0f°C", c) : String(format: "%.0f°F", c * 9 / 5 + 32)
    }

    public static func watts(_ w: Double) -> String {
        w < 1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.1f W", w)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    public static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
        return "\(n)"
    }
}

extension String {
    /// Builds a String from a fixed-size C char tuple (e.g. `proc_bsdinfo.pbi_name`).
    public init<T>(cTuple: T) {
        var copy = cTuple
        self = withUnsafeBytes(of: &copy) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }
}

public enum Shell {
    /// Runs a command and returns stdout (nil on launch failure or timeout).
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10, env: [String: String]? = nil) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, n in n } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static func which(_ name: String, extra: [String] = []) -> String? {
        let home = NSHomeDirectory()
        let dirs = extra + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin",
                            "\(home)/.docker/bin", "\(home)/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
                            "/Applications/OrbStack.app/Contents/MacOS/xbin"]
        for d in dirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(name)") { return "\(d)/\(name)" }
        return nil
    }
}
