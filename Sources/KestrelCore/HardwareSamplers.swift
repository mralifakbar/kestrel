import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - System info

public enum SystemInfo {
    public static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    public static func sysctlInt(_ name: String) -> Int {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &size, nil, 0) != 0 { return 0 }
        if size == 4 { return Int(Int32(truncatingIfNeeded: v)) }
        return Int(v)
    }
    public static var model: String { sysctlString("hw.model") }
    public static var chip: String { sysctlString("machdep.cpu.brand_string") }
    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }
    public static var efficiencyCores: Int {
        // On Apple silicon perflevel0 = performance, perflevel1 = efficiency.
        sysctlInt("hw.nperflevels") > 1 ? sysctlInt("hw.perflevel1.logicalcpu") : 0
    }
    public static var uptime: TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }
    public static var friendlyModel: String {
        let m = model
        if m.hasPrefix("Mac16,10") || m.hasPrefix("Mac16,11") { return "Mac mini" }
        if m.contains("MacBookAir") || ["Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13"].contains(m) { return "MacBook Air" }
        if m.contains("MacBookPro") || m.hasPrefix("Mac14,5") || m.hasPrefix("Mac14,9") || m.hasPrefix("Mac15,3") || m.hasPrefix("Mac15,6") || m.hasPrefix("Mac16,1") || m.hasPrefix("Mac16,5") || m.hasPrefix("Mac16,6") || m.hasPrefix("Mac16,7") || m.hasPrefix("Mac16,8") { return "MacBook Pro" }
        if m.contains("iMac") || m.hasPrefix("Mac15,4") || m.hasPrefix("Mac15,5") || m.hasPrefix("Mac16,2") || m.hasPrefix("Mac16,3") { return "iMac" }
        if m.hasPrefix("Mac13") || m.hasPrefix("Mac14,13") || m.hasPrefix("Mac14,14") || m.hasPrefix("Mac15,14") || m.hasPrefix("Mac16,9") { return "Mac Studio" }
        if m.contains("Macmini") || m.hasPrefix("Mac14,3") || m.hasPrefix("Mac14,12") { return "Mac mini" }
        return "Mac"
    }
}

// MARK: - CPU

public final class CPUSampler {
    private var previous: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private let eCores = SystemInfo.efficiencyCores

    public init() {}

    public func sample() -> CPUStats {
        var stats = CPUStats()
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return stats }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        var current: [(UInt32, UInt32, UInt32, UInt32)] = []
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            current.append((UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        var tu = 0.0, ts = 0.0, tt = 0.0
        for (i, c) in current.enumerated() {
            let p = i < previous.count ? previous[i] : (0, 0, 0, 0)
            let du = Double(c.0 &- p.0) + Double(c.3 &- p.3)
            let ds = Double(c.1 &- p.1)
            let di = Double(c.2 &- p.2)
            let t = max(du + ds + di, 1)
            stats.cores.append(CoreLoad(index: i, isEfficiency: i < eCores, user: du / t, system: ds / t))
            tu += du; ts += ds; tt += t
        }
        previous = current.map { (user: $0.0, system: $0.1, idle: $0.2, nice: $0.3) }
        stats.user = tu / max(tt, 1)
        stats.system = ts / max(tt, 1)
        stats.idle = max(0, 1 - stats.user - stats.system)
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        stats.load1 = loads[0]; stats.load5 = loads[1]; stats.load15 = loads[2]
        return stats
    }
}

// MARK: - Memory

public enum MemorySampler {
    public static func sample() -> MemoryStats {
        var m = MemoryStats()
        m.total = SystemInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.cached = (UInt64(vm.external_page_count) + purgeable) * page
            m.free = UInt64(vm.free_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        let level = SystemInfo.sysctlInt("kern.memorystatus_vm_pressure_level")
        m.pressureLevel = level == 0 ? 1 : level
        let avail = SystemInfo.sysctlInt("kern.memorystatus_level")  // percent of memory available
        m.pressurePercent = avail > 0 ? max(0, min(1, 1 - Double(avail) / 100)) : m.usedFraction
        return m
    }
}

// MARK: - IORegistry helpers

enum IOReg {
    static func forEach(matching name: String, _ body: (io_registry_entry_t, [String: Any]) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let entry = IOIteratorNext(iter), entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] {
                body(entry, dict)
            }
            IOObjectRelease(entry)
        }
    }
    static func first(matching name: String) -> [String: Any]? {
        var out: [String: Any]?
        forEach(matching: name) { _, d in if out == nil { out = d } }
        return out
    }
}

// MARK: - GPU

public enum GPUSampler {
    public static func sample() -> GPUStats {
        var g = GPUStats()
        IOReg.forEach(matching: "IOAccelerator") { _, d in
            guard let perf = d["PerformanceStatistics"] as? [String: Any] else { return }
            let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue ?? (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
            g.utilization = max(g.utilization, util / 100)
            g.renderer = max(g.renderer, ((perf["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0) / 100)
            g.tiler = max(g.tiler, ((perf["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0) / 100)
            g.memoryInUse += (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            if let model = d["model"] as? String { g.name = model }
            else if let cls = d["IOClass"] as? String, g.name == "GPU" { g.name = cls.replacingOccurrences(of: "AGXAccelerator", with: "Apple GPU ") }
        }
        if g.name == "GPU" || g.name.hasPrefix("Apple GPU") { g.name = SystemInfo.chip + " GPU" }
        return g
    }
}

// MARK: - Disk

public final class DiskSampler {
    private var lastRead: UInt64 = 0, lastWrite: UInt64 = 0, lastROps: UInt64 = 0, lastWOps: UInt64 = 0
    private var lastTime: Date?
    private var volumeCache: [VolumeInfo] = []
    private var volumeTime = Date.distantPast

    public init() {}

    public func sample() -> DiskStats {
        var s = DiskStats()
        var r: UInt64 = 0, w: UInt64 = 0, ro: UInt64 = 0, wo: UInt64 = 0
        IOReg.forEach(matching: "IOBlockStorageDriver") { _, d in
            guard let st = d["Statistics"] as? [String: Any] else { return }
            r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            ro += (st["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
            wo += (st["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let now = Date()
        if let lt = lastTime {
            let dt = max(now.timeIntervalSince(lt), 0.001)
            s.readBps = Double(r &- lastRead) / dt
            s.writeBps = Double(w &- lastWrite) / dt
            s.readOps = Double(ro &- lastROps) / dt
            s.writeOps = Double(wo &- lastWOps) / dt
        }
        lastRead = r; lastWrite = w; lastROps = ro; lastWOps = wo; lastTime = now
        s.totalRead = r; s.totalWritten = w
        if now.timeIntervalSince(volumeTime) > 15 { volumeCache = Self.volumes(); volumeTime = now }
        s.volumes = volumeCache
        return s
    }

    public static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false, let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage.map { UInt64($0) } ?? UInt64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path, total: UInt64(total), free: free,
                              isRemovable: v.volumeIsRemovable ?? false, isInternal: v.volumeIsInternal ?? false,
                              format: v.volumeLocalizedFormatDescription ?? "")
        }
    }
}

// MARK: - Network

public final class NetworkSampler {
    private var last: [String: (UInt64, UInt64)] = [:]
    private var lastTime: Date?

    public init() {}

    private static func counters() -> [String: (ibytes: UInt64, obytes: UInt64, up: Bool)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64, Bool)] = [:]
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        out[n] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes, (h2.ifm_flags & IFF_UP) != 0)
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return out.mapValues { (ibytes: $0.0, obytes: $0.1, up: $0.2) }
    }

    private static func addresses() -> [String: [String]] {
        var out: [String: [String]] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let a = String(cString: host)
                    if !a.hasPrefix("fe80") { out[name, default: []].append(a) }
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
    }

    static func primaryInterface() -> String {
        guard let out = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 2) else { return "" }
        for line in out.split(separator: "\n") where line.contains("interface:") {
            return line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return ""
    }

    private var primaryCache = ""
    private var primaryTime = Date.distantPast
    private var addrCache: [String: [String]] = [:]

    public func sample() -> NetworkStats {
        var s = NetworkStats()
        let now = Date()
        let c = Self.counters()
        if now.timeIntervalSince(primaryTime) > 20 {
            primaryCache = Self.primaryInterface()
            addrCache = Self.addresses()
            primaryTime = now
        }
        let dt = lastTime.map { max(now.timeIntervalSince($0), 0.001) }
        for (name, v) in c.sorted(by: { $0.key < $1.key }) {
            let interesting = name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip")
            guard interesting, v.ibytes + v.obytes > 0 else { continue }
            var inB = 0.0, outB = 0.0
            if let dt, let p = last[name] {
                inB = Double(v.ibytes &- p.0) / dt
                outB = Double(v.obytes &- p.1) / dt
                if inB < 0 || inB > 1e12 { inB = 0 }
                if outB < 0 || outB > 1e12 { outB = 0 }
            }
            let display: String
            if name.hasPrefix("utun") { display = "VPN / Tunnel (\(name))" }
            else if name.hasPrefix("bridge") { display = "Bridge (\(name))" }
            else if name == "en0" { display = SystemInfo.friendlyModel.contains("Book") || SystemInfo.friendlyModel.contains("Air") ? "Wi‑Fi (en0)" : "Ethernet (en0)" }
            else if name == "en1" { display = SystemInfo.friendlyModel == "Mac mini" || SystemInfo.friendlyModel == "Mac Studio" || SystemInfo.friendlyModel == "iMac" ? "Wi‑Fi (en1)" : "Thunderbolt (en1)" }
            else { display = name }
            s.interfaces.append(InterfaceStats(name: name, displayName: display, inBps: inB, outBps: outB, totalIn: v.ibytes, totalOut: v.obytes, addresses: addrCache[name] ?? [], isUp: v.up))
            if !name.hasPrefix("utun") && !name.hasPrefix("bridge") {
                s.inBps += inB; s.outBps += outB
                s.totalIn += v.ibytes; s.totalOut += v.obytes
            }
        }
        last = c.mapValues { ($0.ibytes, $0.obytes) }
        lastTime = now
        s.primaryInterface = primaryCache
        s.interfaces.sort { ($0.name == primaryCache ? 0 : 1, $0.name) < ($1.name == primaryCache ? 0 : 1, $1.name) }
        return s
    }
}

// MARK: - Battery & power assertions

public enum BatterySampler {
    public static func sample() -> BatteryStats {
        var b = BatteryStats()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                b.present = true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
                b.percent = mx > 0 ? Double(cur) / Double(mx) : 0
                b.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
                b.isPluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let ttE = d[kIOPSTimeToEmptyKey] as? Int ?? -1
                let ttF = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
                if b.isCharging, ttF > 0 { b.timeRemainingMinutes = ttF } else if !b.isPluggedIn, ttE > 0 { b.timeRemainingMinutes = ttE }
                b.condition = d["BatteryHealth"] as? String ?? ""
            }
        }
        guard b.present, let d = IOReg.first(matching: "AppleSmartBattery") else { return b }
        b.cycleCount = d["CycleCount"] as? Int ?? 0
        b.temperatureC = Double(d["Temperature"] as? Int ?? 0) / 100
        b.designCapacity = d["DesignCapacity"] as? Int ?? 0
        b.maxCapacity = d["AppleRawMaxCapacity"] as? Int ?? d["NominalChargeCapacity"] as? Int ?? 0
        b.currentCapacity = d["AppleRawCurrentCapacity"] as? Int ?? 0
        b.voltage = Double(d["Voltage"] as? Int ?? 0) / 1000
        let amps = (d["InstantAmperage"] as? NSNumber)?.int64Value ?? (d["Amperage"] as? NSNumber)?.int64Value ?? 0
        b.amperage = Double(amps) / 1000
        b.powerDrawW = -b.amperage * b.voltage
        if let ad = d["AdapterDetails"] as? [String: Any] { b.adapterWatts = Double(ad["Watts"] as? Int ?? 0) }
        return b
    }

    public static func sleepBlockers() -> [SleepBlocker] {
        var result: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess, let dict = result?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [SleepBlocker] = []
        let interesting: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "PreventDiskIdle"]
        for (pidNum, list) in dict {
            let pid = pidNum.int32Value
            for a in list {
                let type = a["AssertType"] as? String ?? ""
                guard interesting.contains(type) else { continue }
                let name = a["AssertName"] as? String ?? ""
                out.append(SleepBlocker(pid: pid, process: ProcessNames.name(pid), type: friendlyAssertion(type), name: name))
            }
        }
        return out.sorted { $0.process < $1.process }
    }

    static func friendlyAssertion(_ t: String) -> String {
        switch t {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": return "Prevents sleep"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "Keeps display on"
        case "PreventSystemSleep": return "Blocks system sleep"
        case "PreventDiskIdle": return "Keeps disk awake"
        default: return t
        }
    }
}

public enum ProcessNames {
    public static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") { return URL(fileURLWithPath: String(path[..<r.lowerBound])).lastPathComponent }
            return URL(fileURLWithPath: path).lastPathComponent
        }
        var nb = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nb, UInt32(nb.count))
        let n = String(cString: nb)
        return n.isEmpty ? "pid \(pid)" : n
    }
    public static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }
}
