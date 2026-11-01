import Foundation

public struct CoreLoad: Codable, Hashable {
    public var index: Int
    public var isEfficiency: Bool
    public var user: Double     // 0...1
    public var system: Double
    public var total: Double { user + system }
}

public struct CPUStats: Codable {
    public var user: Double = 0      // 0...1 of whole machine
    public var system: Double = 0
    public var idle: Double = 1
    public var load1: Double = 0
    public var load5: Double = 0
    public var load15: Double = 0
    public var cores: [CoreLoad] = []
    public var total: Double { user + system }
    public var coreCount: Int { max(cores.count, 1) }
    public init() {}
}

public struct MemoryStats: Codable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var pressureLevel: Int = 1        // 1 normal, 2 warning, 4 critical
    public var pressurePercent: Double = 0   // 0...1, how much is under pressure
    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var pressureName: String { pressureLevel >= 4 ? "Critical" : pressureLevel >= 2 ? "Warning" : "Normal" }
    public init() {}
}

public struct GPUStats: Codable {
    public var name: String = "GPU"
    public var utilization: Double = 0   // 0...1
    public var renderer: Double = 0
    public var tiler: Double = 0
    public var memoryInUse: UInt64 = 0
    public var frequencyMHz: Double = 0
    public init() {}
}

public struct PowerStats: Codable {
    public var available: Bool = false
    public var cpuWatts: Double = 0
    public var gpuWatts: Double = 0
    public var aneWatts: Double = 0
    public var dramWatts: Double = 0
    public var systemWatts: Double = 0     // whole-system input when known
    public var memReadBps: Double = 0
    public var memWriteBps: Double = 0
    public var cpuFreqMHz: [String: Double] = [:]  // cluster -> MHz
    public var gpuFreqMHz: Double = 0
    public var aneActive: Double = 0       // 0...1 estimate
    public var packageWatts: Double { cpuWatts + gpuWatts + aneWatts + dramWatts }
    public init() {}
}

public struct VolumeInfo: Codable, Hashable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var total: UInt64
    public var free: UInt64
    public var isRemovable: Bool
    public var isInternal: Bool
    public var format: String
    public var usedFraction: Double { total > 0 ? 1 - Double(free) / Double(total) : 0 }
}

public struct DiskStats: Codable {
    public var readBps: Double = 0
    public var writeBps: Double = 0
    public var readOps: Double = 0
    public var writeOps: Double = 0
    public var totalRead: UInt64 = 0
    public var totalWritten: UInt64 = 0
    public var volumes: [VolumeInfo] = []
    public init() {}
}

public struct InterfaceStats: Codable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var inBps: Double
    public var outBps: Double
    public var totalIn: UInt64
    public var totalOut: UInt64
    public var addresses: [String]
    public var isUp: Bool
}

public struct NetworkStats: Codable {
    public var inBps: Double = 0
    public var outBps: Double = 0
    public var totalIn: UInt64 = 0
    public var totalOut: UInt64 = 0
    public var interfaces: [InterfaceStats] = []
    public var primaryInterface: String = ""
    public init() {}
}

public struct BatteryStats: Codable {
    public var present: Bool = false
    public var percent: Double = 0
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var timeRemainingMinutes: Int? = nil
    public var cycleCount: Int = 0
    public var temperatureC: Double = 0
    public var designCapacity: Int = 0
    public var maxCapacity: Int = 0
    public var currentCapacity: Int = 0
    public var voltage: Double = 0
    public var amperage: Double = 0
    public var powerDrawW: Double = 0       // positive when discharging
    public var adapterWatts: Double = 0
    public var condition: String = ""
    public var health: Double { designCapacity > 0 ? min(Double(maxCapacity) / Double(designCapacity), 1.2) : 0 }
    public init() {}
}

public struct SleepBlocker: Codable, Hashable, Identifiable {
    public var id: String { "\(pid)-\(type)-\(name)" }
    public var pid: Int32
    public var process: String
    public var type: String
    public var name: String
}

public struct SensorReading: Codable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var group: String  // CPU, GPU, Memory, Battery, Other
    public var celsius: Double
}

public struct FanInfo: Codable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double
    public var isManual: Bool
    public var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

public struct ThermalStats: Codable {
    public var cpuC: Double = 0
    public var gpuC: Double = 0
    public var sensors: [SensorReading] = []
    public var fans: [FanInfo] = []
    public var thermalState: String = "Nominal"
    public init() {}
}

public struct BluetoothDevice: Codable, Hashable, Identifiable {
    public var id: String { name + (address ?? "") }
    public var name: String
    public var address: String?
    public var kind: String
    public var connected: Bool
    public var battery: Int?
    public var batteryLeft: Int?
    public var batteryRight: Int?
    public var batteryCase: Int?
}

public struct AppUsage: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var bundleID: String?
    public var isSystem: Bool
    public var cpu: Double            // percent, 100 = one core
    public var memory: UInt64
    public var diskReadBps: Double
    public var diskWriteBps: Double
    public var netInBps: Double
    public var netOutBps: Double
    public var energy: Double         // relative watts estimate
    public var processCount: Int
    public var threads: Int
    public var pids: [Int32]
    public var mainPID: Int32
}

public struct ProcessUsage: Codable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String
    public var cpu: Double
    public var memory: UInt64
    public var diskReadBps: Double
    public var diskWriteBps: Double
    public var netInBps: Double
    public var netOutBps: Double
    public var threads: Int
    public var groupID: String
    public var startTime: Date?
}

public struct SystemSnapshot: Codable {
    public var timestamp = Date()
    public var hostName = Host.current().localizedName ?? "Mac"
    public var model = ""
    public var chip = ""
    public var uptime: TimeInterval = 0
    public var cpu = CPUStats()
    public var memory = MemoryStats()
    public var gpu = GPUStats()
    public var power = PowerStats()
    public var disk = DiskStats()
    public var network = NetworkStats()
    public var battery = BatteryStats()
    public var thermals = ThermalStats()
    public var apps: [AppUsage] = []
    public var processes: [ProcessUsage] = []
    public init() {}
}
