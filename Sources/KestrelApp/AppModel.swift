import SwiftUI
import Combine
import KestrelCore

enum Section: String, CaseIterable, Identifiable, Codable {
    case overview, apps, cpu, memory, disk, network, gpu, neural, power, thermals, sound, bluetooth, projects, agents, containers, history
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .apps: "Apps"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .neural: "Neural Engine"
        case .power: "Power & Battery"
        case .thermals: "Thermals & Fans"
        case .sound: "Sound"
        case .bluetooth: "Bluetooth"
        case .projects: "Projects"
        case .agents: "Agents"
        case .containers: "Containers"
        case .history: "History"
        }
    }

    var plainTitle: String {
        switch self {
        case .neural: "Neural Engine"
        case .power: "Power & Battery"
        case .thermals: "Thermals & Fans"
        default: rawValue == "cpu" || rawValue == "gpu" ? rawValue.uppercased() : rawValue.capitalized
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .apps: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "rectangle.3.group"
        case .neural: "brain"
        case .power: "bolt"
        case .thermals: "thermometer.medium"
        case .sound: "speaker.wave.2"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .projects: "folder.badge.gearshape"
        case .agents: "sparkles"
        case .containers: "shippingbox"
        case .history: "clock.arrow.circlepath"
        }
    }

    var group: String {
        switch self {
        case .overview, .apps, .history: "Monitor"
        case .cpu, .memory, .disk, .network, .gpu, .neural, .power, .thermals: "Hardware"
        case .sound, .bluetooth: "Devices"
        case .projects, .agents, .containers: "Developer"
        }
    }
}

/// Series kept in memory for live graphs.
struct Series {
    var values: [Double] = []
    let capacity: Int
    init(capacity: Int = 150) { self.capacity = capacity }
    mutating func push(_ v: Double) {
        values.append(v.isFinite ? v : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    var last: Double { values.last ?? 0 }
    var max: Double { values.max() ?? 0 }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var snapshot = SystemSnapshot()
    @Published var series: [String: Series] = [:]
    @Published var appSeries: [String: Series] = [:]
    @Published var coreSeries: [Int: Series] = [:]
    @Published var holders: [PortHolder] = []
    @Published var projects: [ProjectGroup] = []
    @Published var agents: [AgentSession] = []
    @Published var containers: [ContainerInfo] = []
    @Published var dockerAvailable = false
    @Published var limits: [ProviderLimits] = []
    @Published var limitsLoading = false
    @Published var tokens: [TokenUsage] = []
    @Published var bluetooth: [BluetoothDevice] = []
    @Published var sleepBlockers: [SleepBlocker] = []
    @Published var selection: Section? = .overview
    @Published var selectedAppID: String?
    @Published var inspectedPID: Int32?
    @Published var windowVisible = false
    @Published var activeSection: Section = .overview

    let history = HistoryStore()
    private let devTracker = DevServerTracker()
    private let agentTracker = AgentTracker()
    private let tokenCounter = TokenCounter()
    private let queue = DispatchQueue(label: "kestrel.sampler", qos: .utility)
    private let slowQueue = DispatchQueue(label: "kestrel.slow", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var currentInterval: Double = 0
    private var lastDev = Date.distantPast, lastDocker = Date.distantPast, lastLimits = Date.distantPast
    private var lastTokens = Date.distantPast, lastBT = Date.distantPast, lastBlockers = Date.distantPast, lastPrune = Date.distantPast
    private var accum: [String: (Double, Int)] = [:]
    private var accumApps: [String: (AppUsage, Double, UInt64, Int)] = [:]
    private var lastHistoryWrite = Date()
    private var slowBusy = false

    var onSample: ((SystemSnapshot) -> Void)?
    nonisolated let visibleFlag = AtomicBool()

    private init() {}

    func start() {
        reschedule()
        refreshSlow(force: true)
    }

    var interval: Double {
        let fast = UserDefaults.standard.double(forKey: "fastInterval")
        return windowVisible ? (fast > 0 ? fast : 1) : 5
    }

    func reschedule() {
        let iv = interval
        guard iv != currentInterval else { return }
        currentInterval = iv
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: iv, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Runs on `queue`.
    nonisolated private func tick() {
        // Per-app network needs `nettop`; only run it when someone will look at it.
        let wantNet = UserDefaults.standard.bool(forKey: "alerts.network") || visibleFlag.value
        MonitorBox.shared.monitor.processSampler.collectNetwork = wantNet
        let snap = MonitorBox.shared.monitor.sample()
        DispatchQueue.main.async { [weak self] in self?.apply(snap) }
    }

    private func apply(_ s: SystemSnapshot) {
        // Mutate local copies and publish once, so SwiftUI sees one change per sample.
        var ser = series
        func push(_ k: String, _ v: Double) { ser[k, default: Series()].push(v) }
        push("cpu", s.cpu.total); push("cpu_user", s.cpu.user); push("cpu_system", s.cpu.system)
        push("mem", s.memory.usedFraction); push("mem_pressure", s.memory.pressurePercent); push("mem_used", Double(s.memory.used))
        push("gpu", s.gpu.utilization)
        push("net_in", s.network.inBps); push("net_out", s.network.outBps)
        push("disk_read", s.disk.readBps); push("disk_write", s.disk.writeBps)
        push("cpu_w", s.power.cpuWatts); push("gpu_w", s.power.gpuWatts); push("ane_w", s.power.aneWatts); push("dram_w", s.power.dramWatts)
        push("sys_w", s.power.systemWatts > 0 ? s.power.systemWatts : s.battery.powerDrawW)
        push("mem_bw", s.power.memReadBps + s.power.memWriteBps)
        push("temp_cpu", s.thermals.cpuC); push("temp_gpu", s.thermals.gpuC)
        push("fan", s.thermals.fans.first?.rpm ?? 0)
        push("battery", s.battery.percent)
        var cores = coreSeries
        for c in s.cpu.cores { cores[c.index, default: Series(capacity: 60)].push(c.total) }
        let live = Set(s.apps.map(\.id))
        var appS = appSeries.filter { live.contains($0.key) }
        for a in s.apps { appS[a.id, default: Series(capacity: 120)].push(a.cpu) }
        snapshot = s
        series = ser
        coreSeries = cores
        appSeries = appS

        AlertEngine.shared.evaluate(s)
        accumulateHistory(s)
        onSample?(s)
        refreshSlow(force: false)
    }

    // MARK: history

    private func accumulateHistory(_ s: SystemSnapshot) {
        for (k, v) in SystemMonitor.historyMetrics(s) {
            let c = accum[k] ?? (0, 0)
            accum[k] = (c.0 + v, c.1 + 1)
        }
        for a in s.apps {
            let c = accumApps[a.id] ?? (a, 0, 0, 0)
            accumApps[a.id] = (a, c.1 + a.cpu, max(c.2, a.memory), c.3 + 1)
        }
        let now = Date()
        guard now.timeIntervalSince(lastHistoryWrite) >= 60 else { return }
        let n = max(accum["cpu"]?.1 ?? 1, 1)
        let metrics = accum.mapValues { $0.0 / Double(max($0.1, 1)) }
        var apps = accumApps.values.map { v -> AppUsage in
            var a = v.0
            a.cpu = v.1 / Double(n)
            a.memory = v.2
            return a
        }
        apps.sort { $0.cpu > $1.cpu }
        let topCPU = apps.prefix(25)
        let topMem = apps.sorted { $0.memory > $1.memory }.prefix(15)
        let keep = Dictionary((Array(topCPU) + Array(topMem)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        history.record(metrics: metrics, apps: Array(keep.values), at: now)
        accum = [:]; accumApps = [:]
        lastHistoryWrite = now
        if now.timeIntervalSince(lastPrune) > 6 * 3600 {
            history.prune(retentionDays: KestrelPrefs.historyRetentionDays)
            lastPrune = now
        }
    }

    // MARK: slower data sources

    func refreshSlow(force: Bool) {
        guard !slowBusy else { return }
        let now = Date()
        let vis = windowVisible
        let sec = activeSection
        let procs = snapshot.processes
        let wantDev = force || now.timeIntervalSince(lastDev) > (vis && [.projects, .agents, .overview].contains(sec) ? 3 : 15)
        let wantDocker = force || now.timeIntervalSince(lastDocker) > (vis && sec == .containers ? 4 : 60)
        let wantLimits = KestrelPrefs.limitsEnabled && (force || now.timeIntervalSince(lastLimits) > 300)
        let wantTokens = force || now.timeIntervalSince(lastTokens) > (vis && sec == .agents ? 30 : 180)
        let wantBT = force || now.timeIntervalSince(lastBT) > (vis && sec == .bluetooth ? 20 : 120)
        let wantBlockers = force || now.timeIntervalSince(lastBlockers) > 15
        guard wantDev || wantDocker || wantLimits || wantTokens || wantBT || wantBlockers else { return }
        if wantDev { lastDev = now }
        if wantDocker { lastDocker = now }
        if wantLimits { lastLimits = now; limitsLoading = true }
        if wantTokens { lastTokens = now }
        if wantBT { lastBT = now }
        if wantBlockers { lastBlockers = now }
        slowBusy = true
        let dev = devTracker, ag = agentTracker, tc = tokenCounter
        slowQueue.async { [weak self] in
            let holders = (wantDev && !procs.isEmpty) ? dev.scan(processes: procs) : nil
            let agents = (wantDev && !procs.isEmpty) ? ag.scan(processes: procs) : nil
            let docker = wantDocker ? Docker.containers() : nil
            let limits = wantLimits ? UsageLimits.fetchAll() : nil
            let tokens = wantTokens ? tc.usage() : nil
            let bt = wantBT ? BluetoothSampler.sample() : nil
            let blockers = wantBlockers ? BatterySampler.sleepBlockers() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let holders { self.holders = holders; self.projects = DevServerTracker.group(holders) }
                if let agents { self.agents = agents }
                if let docker { self.dockerAvailable = docker.available; self.containers = docker.items }
                if let limits { self.limits = limits; self.limitsLoading = false }
                if let tokens { self.tokens = tokens }
                if let bt { self.bluetooth = bt }
                if let blockers { self.sleepBlockers = blockers }
                self.slowBusy = false
            }
        }
    }

    func forceRefreshLimits() { lastLimits = .distantPast; refreshSlow(force: false) }
    func forceRefreshDocker() { lastDocker = .distantPast; refreshSlow(force: false) }
    func forceRefreshDev() { lastDev = .distantPast; refreshSlow(force: false) }

    func setWindowVisible(_ v: Bool) {
        windowVisible = v
        visibleFlag.value = v
        reschedule()
    }

    func open(section: Section, app: String? = nil, pid: Int32? = nil) {
        selection = section
        activeSection = section
        if let app { selectedAppID = app }
        if let pid { inspectedPID = pid }
        WindowOpener.openMain()
    }

    var cores: Int { snapshot.cpu.coreCount }
}

/// Owns the sampler so it is only touched from the sampling queue.
final class MonitorBox {
    static let shared = MonitorBox()
    let monitor = SystemMonitor()
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
