import Foundation

/// Samples every subsystem. Not thread-safe: call from one queue.
public final class SystemMonitor {
    private let cpuSampler = CPUSampler()
    private let diskSampler = DiskSampler()
    private let netSampler = NetworkSampler()
    public let powerSampler = PowerSampler()
    public let processSampler = ProcessSampler()
    private var thermalCache = ThermalStats()
    private var thermalTime = Date.distantPast
    private var batteryCache = BatteryStats()
    private var batteryTime = Date.distantPast

    public init() {}

    public func sample(includeProcesses: Bool = true) -> SystemSnapshot {
        var s = SystemSnapshot()
        s.model = SystemInfo.friendlyModel
        s.chip = SystemInfo.chip
        s.uptime = SystemInfo.uptime
        s.cpu = cpuSampler.sample()
        s.memory = MemorySampler.sample()
        s.gpu = GPUSampler.sample()
        s.power = powerSampler.sample()
        s.disk = diskSampler.sample()
        s.network = netSampler.sample()
        let now = Date()
        if now.timeIntervalSince(batteryTime) > 4 { batteryCache = BatterySampler.sample(); batteryTime = now }
        s.battery = batteryCache
        if now.timeIntervalSince(thermalTime) > 3 { thermalCache = SMC.thermals(); thermalTime = now }
        s.thermals = thermalCache
        if includeProcesses {
            let r = processSampler.sample(cores: s.cpu.coreCount)
            s.apps = r.apps
            s.processes = r.processes
            // Distribute measured CPU+GPU package power across apps by CPU share.
            let pkg = s.power.cpuWatts + s.power.gpuWatts
            if pkg > 0 { for i in s.apps.indices { s.apps[i].energy *= pkg } }
        }
        return s
    }

    /// Two samples a second apart, for one-shot consumers (CLI / MCP).
    public func warmSample(includeProcesses: Bool = true, interval: TimeInterval = 1.0) -> SystemSnapshot {
        processSampler.collectNetwork = false
        _ = sample(includeProcesses: includeProcesses)
        Thread.sleep(forTimeInterval: interval)
        return sample(includeProcesses: includeProcesses)
    }

    public static func historyMetrics(_ s: SystemSnapshot) -> [String: Double] {
        var m: [String: Double] = [
            "cpu": s.cpu.total, "cpu_user": s.cpu.user, "cpu_system": s.cpu.system, "load1": s.cpu.load1,
            "mem_used": Double(s.memory.used), "mem_pressure": s.memory.pressurePercent, "swap": Double(s.memory.swapUsed),
            "gpu": s.gpu.utilization, "disk_read": s.disk.readBps, "disk_write": s.disk.writeBps,
            "net_in": s.network.inBps, "net_out": s.network.outBps,
        ]
        if s.power.available {
            m["cpu_w"] = s.power.cpuWatts; m["gpu_w"] = s.power.gpuWatts; m["ane_w"] = s.power.aneWatts; m["dram_w"] = s.power.dramWatts
            if s.power.systemWatts > 0 { m["sys_w"] = s.power.systemWatts }
        }
        if s.thermals.cpuC > 0 { m["temp_cpu"] = s.thermals.cpuC }
        if s.thermals.gpuC > 0 { m["temp_gpu"] = s.thermals.gpuC }
        if let f = s.thermals.fans.first { m["fan0"] = f.rpm }
        if s.battery.present { m["battery"] = s.battery.percent; m["battery_w"] = s.battery.powerDrawW }
        return m
    }
}
