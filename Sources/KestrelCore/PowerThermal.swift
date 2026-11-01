import Foundation
import CKestrel

// MARK: - IOReport power (Apple silicon)

public final class PowerSampler {
    private var subscription: IOReportSubscriptionRef?
    private var subscribed: Unmanaged<CFMutableDictionary>?
    private var previous: CFDictionary?
    private var previousTime = Date()
    public private(set) var available = false

    public init() {
        var merged: CFMutableDictionary?
        for (group, sub) in [("Energy Model", nil), ("AMC Stats", "Perf Counters")] as [(String, String?)] {
            guard let ch = IOReportCopyChannelsInGroup(group as CFString, sub as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch)
            } else {
                IOReportMergeChannels(merged!, ch, nil)
            }
        }
        guard let merged else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, merged, &subbed, 0, nil)
        subscribed = subbed
        available = subscription != nil
        if available, let s = subscribed {
            previous = IOReportCreateSamples(subscription, s.takeUnretainedValue(), nil)?.takeRetainedValue()
            previousTime = Date()
        }
    }

    deinit { subscribed?.release() }

    public static func channelNames() -> [String] {
        var out: [String] = []
        for group in ["Energy Model", "AMC Stats", "CPU Stats", "GPU Stats", "PMP"] {
            guard let ch = IOReportCopyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue() as? [String: Any],
                  let list = ch["IOReportChannels"] as? [CFDictionary] else { continue }
            for c in list {
                let sg = IOReportChannelGetSubGroup(c)?.takeUnretainedValue() as String? ?? ""
                let n = IOReportChannelGetChannelName(c)?.takeUnretainedValue() as String? ?? ""
                out.append("\(group) / \(sg) / \(n)")
            }
        }
        return out
    }

    public func sample() -> PowerStats {
        var p = PowerStats()
        guard available, let sub = subscription, let s = subscribed,
              let cur = IOReportCreateSamples(sub, s.takeUnretainedValue(), nil)?.takeRetainedValue() else { return p }
        let now = Date()
        defer { previous = cur; previousTime = now }
        guard let prev = previous, let delta = IOReportCreateSamplesDelta(prev, cur, nil)?.takeRetainedValue() as? [String: Any],
              let channels = delta["IOReportChannels"] as? [CFDictionary] else { return p }
        let dt = max(now.timeIntervalSince(previousTime), 0.05)
        p.available = true
        var cpuTotal = 0.0, cpuClusters = 0.0, gpuNamed = 0.0, gpuPlain = 0.0
        for ch in channels {
            let group = IOReportChannelGetGroup(ch)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(ch)?.takeUnretainedValue() as String? ?? ""
            let value = Double(IOReportSimpleGetIntegerValue(ch, 0))
            if group == "Energy Model" {
                let unit = (IOReportChannelGetUnitLabel(ch)?.takeUnretainedValue() as String? ?? "mJ").trimmingCharacters(in: .whitespaces)
                let joules: Double
                switch unit {
                case "nJ": joules = value / 1e9
                case "uJ", "µJ": joules = value / 1e6
                default: joules = value / 1e3
                }
                let w = joules / dt
                if name == "CPU Energy" { cpuTotal += w }
                else if name.hasSuffix("CPU") && !name.contains("SRAM") { cpuClusters += w }
                else if name == "GPU Energy" { gpuNamed += w }
                else if name == "GPU" { gpuPlain += w }
                else if name.hasPrefix("ANE") { p.aneWatts += w }
                else if name.hasPrefix("DRAM") { p.dramWatts += w }
            } else if group == "AMC Stats" {
                let bytesPerSec = value / dt
                let n = name.uppercased()
                if n.hasSuffix("DCS RDWR") { p.memReadBps += bytesPerSec / 2; p.memWriteBps += bytesPerSec / 2 }
                else if n.hasSuffix("DCS RD") { p.memReadBps += bytesPerSec }
                else if n.hasSuffix("DCS WR") { p.memWriteBps += bytesPerSec }
            }
        }
        p.cpuWatts = cpuTotal > 0 ? cpuTotal : cpuClusters
        p.gpuWatts = gpuNamed > 0 ? gpuNamed : gpuPlain
        // The Neural Engine idles at ~0 W and peaks around 6–8 W on M-series chips.
        p.aneActive = min(1, p.aneWatts / 6.0)
        if let sys = SMC.value("PSTR"), sys > 0, sys < 1000 { p.systemWatts = sys }
        return p
    }
}

// MARK: - SMC sensors & fans

public enum SMC {
    public static func value(_ key: String) -> Double? {
        var v = KSMCValue()
        guard ksmc_read(key, &v) == 0 else { return nil }
        var ok: Int32 = 0
        let d = ksmc_decode(&v, &ok)
        return ok != 0 ? d : nil
    }

    private static var cachedTempKeys: [String]?
    private static let lock = NSLock()

    public static func temperatureKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedTempKeys { return c }
        var keys: [String] = []
        var count: UInt32 = 0
        if ksmc_key_count(&count) == 0 {
            var buf = [CChar](repeating: 0, count: 5)
            for i in 0..<count {
                guard ksmc_key_at(i, &buf) == 0 else { continue }
                let k = String(cString: buf)
                guard k.hasPrefix("T") else { continue }
                var v = KSMCValue()
                guard ksmc_read(k, &v) == 0 else { continue }
                let type = String(cTuple: v.type)
                if ["flt ", "sp78", "fp88", "ioft"].contains(type) { keys.append(k) }
            }
        }
        cachedTempKeys = keys
        return keys
    }

    static func describe(_ key: String) -> (group: String, name: String) {
        let p2 = String(key.prefix(2))
        switch p2 {
        case "Tp", "TC": return ("CPU", "CPU performance core \(key)")
        case "Te": return ("CPU", "CPU efficiency core \(key)")
        case "Tg", "TG": return ("GPU", "GPU \(key)")
        case "Tm": return ("Memory", "Memory \(key)")
        case "TB": return ("Battery", "Battery \(key)")
        case "TH", "TN": return ("Storage", "SSD \(key)")
        case "TW": return ("Wireless", "Wi‑Fi \(key)")
        case "Ta", "TA": return ("Ambient", "Ambient \(key)")
        case "Ts": return ("Chassis", "Palm rest \(key)")
        case "TP", "TV", "Tz": return ("Power", "Power supply \(key)")
        default: return ("Other", key)
        }
    }

    public static func thermals() -> ThermalStats {
        var t = ThermalStats()
        var cpu: [Double] = [], gpu: [Double] = []
        for k in temperatureKeys() {
            guard let c = value(k), c > 15, c < 130 else { continue }
            let d = describe(k)
            t.sensors.append(SensorReading(key: k, name: d.name, group: d.group, celsius: c))
            if d.group == "CPU" { cpu.append(c) }
            if d.group == "GPU" { gpu.append(c) }
        }
        t.cpuC = cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count)
        t.gpuC = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count)
        t.fans = fans()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: t.thermalState = "Nominal"
        case .fair: t.thermalState = "Fair"
        case .serious: t.thermalState = "Serious"
        case .critical: t.thermalState = "Critical"
        @unknown default: t.thermalState = "Unknown"
        }
        return t
    }

    public static func fans() -> [FanInfo] {
        let n = Int(value("FNum") ?? 0)
        return (0..<n).map { i in
            FanInfo(index: i, rpm: value("F\(i)Ac") ?? 0, minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? 0,
                    targetRPM: value("F\(i)Tg") ?? 0, isManual: (value("F\(i)Md") ?? 0) == 1)
        }
    }
}

// MARK: - Bluetooth

public enum BluetoothSampler {
    public static func sample() -> [BluetoothDevice] {
        var devices: [BluetoothDevice] = []
        // Apple HID peripherals (Magic Keyboard / Mouse / Trackpad) expose battery in the IORegistry.
        IOReg.forEach(matching: "AppleDeviceManagementHIDEventService") { _, d in
            guard let pct = d["BatteryPercent"] as? Int else { return }
            let name = d["Product"] as? String ?? "Accessory"
            let addr = d["DeviceAddress"] as? String
            devices.append(BluetoothDevice(name: name, address: addr, kind: kind(name), connected: true, battery: pct))
        }
        // Everything else (AirPods, Beats, third-party) comes from system_profiler.
        if let json = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15),
           let data = json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["SPBluetoothDataType"] as? [[String: Any]] {
            for section in arr {
                for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                    guard let list = section[key] as? [[String: Any]] else { continue }
                    for entry in list {
                        for (name, raw) in entry {
                            guard let info = raw as? [String: Any] else { continue }
                            let addr = info["device_address"] as? String
                            func pct(_ k: String) -> Int? { (info[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
                            var dev = BluetoothDevice(name: name, address: addr, kind: (info["device_minorType"] as? String) ?? kind(name), connected: connected,
                                                      battery: pct("device_batteryLevelMain") ?? pct("device_batteryLevel"),
                                                      batteryLeft: pct("device_batteryLevelLeft"), batteryRight: pct("device_batteryLevelRight"),
                                                      batteryCase: pct("device_batteryLevelCase"))
                            if let i = devices.firstIndex(where: { ($0.address != nil && $0.address?.lowercased() == addr?.lowercased()) || $0.name == name }) {
                                dev.battery = devices[i].battery ?? dev.battery
                                devices[i] = dev
                            } else {
                                devices.append(dev)
                            }
                        }
                    }
                }
            }
        }
        return devices.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    static func kind(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "Keyboard" }
        if n.contains("mouse") { return "Mouse" }
        if n.contains("trackpad") { return "Trackpad" }
        if n.contains("airpods") || n.contains("beats") || n.contains("buds") || n.contains("headphone") { return "Headphones" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "Game Controller" }
        return "Device"
    }
}
