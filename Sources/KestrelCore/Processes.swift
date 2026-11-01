import Foundation
import Darwin
import CKestrel

public enum Mach {
    public static let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(tb.denom))
    }()
    public static func toNanos(_ t: UInt64) -> Double { Double(t) * timebase.numer / timebase.denom }
}

public struct RawProc {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String
    public var cpuNs: Double
    public var userNs: Double
    public var systemNs: Double
    public var footprint: UInt64
    public var peakFootprint: UInt64
    public var diskRead: UInt64
    public var diskWrite: UInt64
    public var threads: Int
    public var startTime: Date?
    public var hasRusage: Bool
}

public enum ProcInfo {
    public static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 128)
        let c = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(c, 0)))).filter { $0 > 0 }
    }

    public static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    public static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var ri = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ri) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? ri : nil
    }

    public static func threadCount(_ pid: Int32) -> Int {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size ? Int(ti.pti_threadnum) : 0
    }

    public static func raw(_ pid: Int32) -> RawProc? {
        guard let bsd = bsdInfo(pid) else {
            if pid == 0 { return RawProc(pid: 0, ppid: 0, uid: 0, name: "kernel_task", path: "", cpuNs: 0, userNs: 0, systemNs: 0, footprint: 0, peakFootprint: 0, diskRead: 0, diskWrite: 0, threads: 0, startTime: nil, hasRusage: false) }
            return nil
        }
        var name = String(cTuple: bsd.pbi_name)
        if name.isEmpty { name = String(cTuple: bsd.pbi_comm) }
        let path = ProcessNames.path(pid)
        if !path.isEmpty, name.count >= 15 { name = URL(fileURLWithPath: path).lastPathComponent }
        let start = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
        var p = RawProc(pid: pid, ppid: Int32(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path, cpuNs: 0, userNs: 0, systemNs: 0,
                        footprint: 0, peakFootprint: 0, diskRead: 0, diskWrite: 0, threads: 0, startTime: start, hasRusage: false)
        if let ri = rusage(pid) {
            p.userNs = Mach.toNanos(ri.ri_user_time)
            p.systemNs = Mach.toNanos(ri.ri_system_time)
            p.cpuNs = p.userNs + p.systemNs
            p.footprint = ri.ri_phys_footprint
            p.peakFootprint = ri.ri_lifetime_max_phys_footprint
            p.diskRead = ri.ri_diskio_bytesread
            p.diskWrite = ri.ri_diskio_byteswritten
            p.hasRusage = true
        }
        p.threads = threadCount(pid)
        return p
    }

    public static func children(of pid: Int32) -> [Int32] {
        var buf = [Int32](repeating: 0, count: 2048)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<Int32>.size))
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    /// All descendants, depth first, by walking ppid links (more reliable than proc_listchildpids for reparented trees).
    public static func descendants(of root: Int32, ppidMap: [Int32: Int32]? = nil) -> [Int32] {
        let map = ppidMap ?? Dictionary(uniqueKeysWithValues: allPIDs().compactMap { pid in bsdInfo(pid).map { (pid, Int32($0.pbi_ppid)) } })
        var childrenOf: [Int32: [Int32]] = [:]
        for (c, p) in map { childrenOf[p, default: []].append(c) }
        var out: [Int32] = []
        var stack = childrenOf[root] ?? []
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: childrenOf[n] ?? [])
        }
        return out
    }

    public static func cwd(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let s = String(cTuple: vpi.pvi_cdir.vip_path)
        return s.isEmpty ? nil : s
    }

    /// argv via KERN_PROCARGS2. Works for processes owned by the current user.
    public static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }       // exec path
        while i < size && buf[i] == 0 { i += 1 }       // padding
        var args: [String] = []
        while args.count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

// MARK: - Grouping helpers into apps

public struct AppIdentity: Hashable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var bundleID: String?
    public var isSystem: Bool
}

public enum AppResolver {
    private static var cache: [String: AppIdentity] = [:]
    private static let lock = NSLock()

    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    public static func identity(for proc: RawProc, responsiblePath: String, responsibleName: String) -> AppIdentity {
        let key = responsiblePath.isEmpty ? "name:\(responsibleName):\(proc.uid == 0 ? "root" : "user")" : responsiblePath
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let id: AppIdentity
        if let app = outermostApp(responsiblePath) {
            let b = Bundle(path: app)
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
            let sys = app.hasPrefix("/System/Library/CoreServices") && !app.hasSuffix("Finder.app") && !app.hasSuffix("Dock.app")
            id = AppIdentity(id: app, name: name, bundlePath: app, bundleID: b?.bundleIdentifier, isSystem: sys)
        } else {
            let isSystem = proc.uid == 0 || proc.uid < 500 || responsiblePath.hasPrefix("/System/") || responsiblePath.hasPrefix("/usr/libexec") || responsiblePath.hasPrefix("/usr/sbin") || responsiblePath.hasPrefix("/sbin") || responsiblePath.isEmpty
            if proc.pid == 0 {
                id = AppIdentity(id: "kernel", name: "macOS Kernel", bundlePath: nil, bundleID: nil, isSystem: true)
            } else if isSystem {
                id = AppIdentity(id: "system", name: "macOS Services", bundlePath: nil, bundleID: nil, isSystem: true)
            } else {
                id = AppIdentity(id: key, name: responsibleName, bundlePath: nil, bundleID: nil, isSystem: false)
            }
        }
        cache[key] = id
        return id
    }
}

// MARK: - Process sampler

public final class ProcessSampler {
    private struct Static {
        var start: UInt64
        var ppid: Int32
        var uid: UInt32
        var name: String
        var path: String
        var startDate: Date
        var identity: AppIdentity?
        var threads: Int = 0
    }
    private var statics: [Int32: Static] = [:]
    private var tick = 0
    private var lastCPU: [Int32: Double] = [:]
    private var lastDisk: [Int32: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    private var psCPU: [Int32: (cpu: Double, rss: UInt64)] = [:]
    private var psTime = Date.distantPast
    private let net = NetTop()
    public var collectNetwork = true

    public init() {}

    /// Uses the setuid `ps` to fill in CPU / memory for processes we can't read directly (other users / root).
    private func refreshPS() {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss="], timeout: 5) else { return }
        var m: [Int32: (Double, UInt64)] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { continue }
            m[pid] = (cpu, rss * 1024)
        }
        psCPU = m.mapValues { (cpu: $0.0, rss: $0.1) }
    }

    public func sample(cores: Int) -> (apps: [AppUsage], processes: [ProcessUsage]) {
        let now = Date()
        let dt = lastTime.map { max(now.timeIntervalSince($0), 0.05) }
        tick += 1
        let refreshThreads = tick % 5 == 1
        let pids = ProcInfo.allPIDs()
        var fresh: [Int32: Static] = [:]
        var usage: [Int32: rusage_info_v4] = [:]
        var needPS = false
        for pid in pids {
            // Static facts are cached per (pid, start time); only resource usage is read every tick.
            let ri = ProcInfo.rusage(pid)
            if let ri { usage[pid] = ri } else { needPS = true }
            if var st = statics[pid], ri == nil || st.start == ri!.ri_proc_start_abstime {
                if refreshThreads { st.threads = ProcInfo.threadCount(pid) }
                fresh[pid] = st
                continue
            }
            guard let raw = ProcInfo.raw(pid) else { continue }
            fresh[pid] = Static(start: ri?.ri_proc_start_abstime ?? 0, ppid: raw.ppid, uid: raw.uid, name: raw.name, path: raw.path,
                                startDate: raw.startTime ?? now, identity: nil, threads: raw.threads)
        }
        statics = fresh
        if needPS && now.timeIntervalSince(psTime) > 5 { refreshPS(); psTime = now }
        let netRates = collectNetwork ? net.rates() : [:]

        // Resolve app identities for new processes.
        for (pid, st) in statics where st.identity == nil {
            let resp = k_responsible_pid(pid)
            let r = statics[resp]
            let rPath = r?.path ?? ProcessNames.path(resp)
            let rName = r?.name ?? ProcessNames.name(resp)
            let ownApp = AppResolver.outermostApp(st.path)
            let rawish = RawProc(pid: pid, ppid: st.ppid, uid: st.uid, name: st.name, path: st.path, cpuNs: 0, userNs: 0, systemNs: 0, footprint: 0, peakFootprint: 0, diskRead: 0, diskWrite: 0, threads: 0, startTime: nil, hasRusage: true)
            statics[pid]?.identity = AppResolver.identity(for: rawish, responsiblePath: ownApp ?? rPath, responsibleName: ownApp != nil ? st.name : rName)
        }

        var procs: [ProcessUsage] = []
        procs.reserveCapacity(statics.count)
        var groups: [String: (AppIdentity, [ProcessUsage])] = [:]
        var newCPU: [Int32: Double] = [:]
        var newDisk: [Int32: (UInt64, UInt64)] = [:]

        for (pid, st) in statics {
            var cpu = 0.0, mem: UInt64 = 0, dr = 0.0, dw = 0.0
            if let ri = usage[pid] {
                let cpuNs = Mach.toNanos(ri.ri_user_time) + Mach.toNanos(ri.ri_system_time)
                mem = ri.ri_phys_footprint
                newCPU[pid] = cpuNs
                newDisk[pid] = (ri.ri_diskio_bytesread, ri.ri_diskio_byteswritten)
                if let dt, let prev = lastCPU[pid] { cpu = max(0, (cpuNs - prev) / (dt * 1e9) * 100) }
                if let dt, let pd = lastDisk[pid] {
                    dr = Double(ri.ri_diskio_bytesread &- pd.0) / dt
                    dw = Double(ri.ri_diskio_byteswritten &- pd.1) / dt
                    if dr < 0 || dr > 1e11 { dr = 0 }
                    if dw < 0 || dw > 1e11 { dw = 0 }
                }
            } else if let ps = psCPU[pid] {
                cpu = ps.cpu; mem = ps.rss
            }
            guard let identity = st.identity else { continue }
            let n = netRates[pid] ?? (0, 0)
            let pu = ProcessUsage(pid: pid, ppid: st.ppid, uid: st.uid, name: st.name, path: st.path, cpu: cpu, memory: mem,
                                  diskReadBps: dr, diskWriteBps: dw, netInBps: n.0, netOutBps: n.1, threads: st.threads,
                                  groupID: identity.id, startTime: st.startDate)
            procs.append(pu)
            groups[identity.id, default: (identity, [])].1.append(pu)
        }
        lastCPU = newCPU
        lastDisk = newDisk
        lastTime = now

        let totalCPU = max(procs.reduce(0) { $0 + $1.cpu }, 0.0001)
        var apps: [AppUsage] = groups.values.map { (identity, members) in
            let main = members.first(where: { $0.path.hasPrefix(identity.bundlePath ?? "\u{0}") && $0.path.contains("/Contents/MacOS/") && !$0.path.contains("Helper") })
                ?? members.min(by: { $0.pid < $1.pid })!
            let cpu = members.reduce(0) { $0 + $1.cpu }
            return AppUsage(id: identity.id, name: identity.name, bundlePath: identity.bundlePath, bundleID: identity.bundleID,
                            isSystem: identity.isSystem, cpu: cpu, memory: members.reduce(0) { $0 + $1.memory },
                            diskReadBps: members.reduce(0) { $0 + $1.diskReadBps }, diskWriteBps: members.reduce(0) { $0 + $1.diskWriteBps },
                            netInBps: members.reduce(0) { $0 + $1.netInBps }, netOutBps: members.reduce(0) { $0 + $1.netOutBps },
                            energy: cpu / totalCPU, processCount: members.count, threads: members.reduce(0) { $0 + $1.threads },
                            pids: members.map(\.pid).sorted(), mainPID: main.pid)
        }
        apps.sort { $0.cpu > $1.cpu }
        return (apps, procs)
    }
}

/// Per-process network counters via `nettop`, refreshed in the background.
final class NetTop {
    private var last: [Int32: (UInt64, UInt64)] = [:]
    private var lastTime: Date?
    private var current: [Int32: (Double, Double)] = [:]
    private var running = false
    private let lock = NSLock()

    private var lastRun = Date.distantPast

    func rates() -> [Int32: (Double, Double)] {
        lock.lock()
        let r = current
        let busy = running || Date().timeIntervalSince(lastRun) < 3
        if !busy { lastRun = Date() }
        if !busy { running = true }
        lock.unlock()
        if !busy {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.refresh() }
        }
        return r
    }

    private func refresh() {
        defer { lock.lock(); running = false; lock.unlock() }
        guard let out = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], timeout: 8) else { return }
        var now: [Int32: (UInt64, UInt64)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."), let pid = Int32(cols[0][cols[0].index(after: dot)...]),
                  let i = UInt64(cols[1]), let o = UInt64(cols[2]) else { continue }
            now[pid] = (i, o)
        }
        let t = Date()
        lock.lock()
        if let lt = lastTime {
            let dt = max(t.timeIntervalSince(lt), 0.1)
            var r: [Int32: (Double, Double)] = [:]
            for (pid, v) in now {
                guard let p = last[pid] else { continue }
                let i = v.0 >= p.0 ? Double(v.0 - p.0) / dt : 0
                let o = v.1 >= p.1 ? Double(v.1 - p.1) / dt : 0
                if i > 0 || o > 0 { r[pid] = (i, o) }
            }
            current = r
        }
        last = now
        lastTime = t
        lock.unlock()
    }
}

// MARK: - Quitting

public enum ProcessControl {
    @discardableResult
    public static func terminate(_ pid: Int32, force: Bool = false) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    /// Quits a process and everything it started (children first).
    @discardableResult
    public static func terminateTree(_ root: Int32, force: Bool = false) -> Int {
        let tree = ProcInfo.descendants(of: root).reversed() + [root]
        var n = 0
        for pid in tree where terminate(pid, force: force) { n += 1 }
        return n
    }
}
