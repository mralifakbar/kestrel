import SwiftUI
import KestrelCore

private let twoCol = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                GaugeTile(title: "CPU", value: s.cpu.total, text: Fmt.percent(s.cpu.total), sub: "load \(String(format: "%.2f", s.cpu.load1))", color: Theme.color(.cpu), section: .cpu)
                GaugeTile(title: "Memory", value: s.memory.usedFraction, text: Fmt.bytes(s.memory.used), sub: "pressure \(s.memory.pressureName.lowercased())", color: s.memory.pressureLevel >= 4 ? Theme.strain : Theme.color(.memory), section: .memory)
                GaugeTile(title: "GPU", value: s.gpu.utilization, text: Fmt.percent(s.gpu.utilization), sub: s.power.available ? Fmt.watts(s.power.gpuWatts) : "", color: Theme.color(.gpu), section: .gpu)
                GaugeTile(title: "Neural Engine", value: s.power.aneActive, text: s.power.aneWatts > 0.01 ? Fmt.watts(s.power.aneWatts) : "Idle", sub: "ANE", color: Theme.color(.neural), section: .neural)
            }
            LazyVGrid(columns: twoCol, spacing: 14) {
                Panel("Network", icon: "network", accessory: { Text("↓ \(Fmt.rate(s.network.inBps))  ↑ \(Fmt.rate(s.network.outBps))").font(.caption.monospacedDigit()) }) {
                    MirrorGraph(up: model.series["net_in"]?.values ?? [], down: model.series["net_out"]?.values ?? [], upColor: Theme.color(.networkIn), downColor: Theme.color(.networkOut)).frame(height: 70)
                }
                .onTapGesture { model.selection = .network }
                Panel("Disk", icon: "internaldrive", accessory: { Text("R \(Fmt.rate(s.disk.readBps))  W \(Fmt.rate(s.disk.writeBps))").font(.caption.monospacedDigit()) }) {
                    MirrorGraph(up: model.series["disk_read"]?.values ?? [], down: model.series["disk_write"]?.values ?? [], upColor: Theme.color(.diskRead), downColor: Theme.color(.diskWrite)).frame(height: 70)
                }
                .onTapGesture { model.selection = .disk }
                Panel(s.battery.present ? "Battery & Power" : "Power", icon: "bolt") {
                    HStack(alignment: .bottom, spacing: 20) {
                        if s.battery.present {
                            BigNumber(value: Fmt.percent(s.battery.percent), caption: s.battery.isCharging ? "Charging" : s.battery.isPluggedIn ? "On power adapter" : "On battery", color: s.battery.percent < 0.15 ? Theme.strain : .primary)
                        }
                        if s.power.available {
                            BigNumber(value: Fmt.watts(s.power.systemWatts > 0 ? s.power.systemWatts : s.power.packageWatts), caption: s.power.systemWatts > 0 ? "System power" : "Chip power")
                        }
                        Sparkline(values: model.series["sys_w"]?.values ?? [], color: Theme.color(.power)).frame(height: 44)
                    }
                }
                .onTapGesture { model.selection = .power }
                Panel("Thermals", icon: "thermometer.medium") {
                    HStack(alignment: .bottom, spacing: 20) {
                        BigNumber(value: Fmt.temp(s.thermals.cpuC), caption: "CPU", color: s.thermals.cpuC > 95 ? Theme.strain : .primary)
                        BigNumber(value: Fmt.temp(s.thermals.gpuC), caption: "GPU")
                        if let f = s.thermals.fans.first { BigNumber(value: "\(Int(f.rpm))", caption: "Fan rpm") }
                        Sparkline(values: model.series["temp_cpu"]?.values ?? [], color: Theme.color(.temperature), maxValue: 110).frame(height: 44)
                    }
                }
                .onTapGesture { model.selection = .thermals }
            }
            LazyVGrid(columns: twoCol, alignment: .leading, spacing: 14) {
                AppsBehind(title: "Busiest apps", sort: { $0.cpu > $1.cpu }, value: { Fmt.cpu($0.cpu, cores: model.cores) },
                           fraction: { $0.cpu / Double(max(model.cores, 1) * 100) * 4 }, color: Theme.color(.cpu), limit: 6)
                VStack(spacing: 14) {
                    Panel("Developer", icon: "hammer") {
                        HStack(spacing: 24) {
                            Button { model.selection = .projects } label: { BigNumber(value: "\(model.holders.count)", caption: "Servers & ports") }.buttonStyle(.plain)
                            Button { model.selection = .agents } label: { BigNumber(value: "\(model.agents.count)", caption: "Coding agents") }.buttonStyle(.plain)
                            Button { model.selection = .containers } label: { BigNumber(value: "\(model.containers.filter { $0.state == "running" }.count)", caption: "Containers") }.buttonStyle(.plain)
                        }
                        let idle = model.holders.filter(\.isIdle)
                        if !idle.isEmpty {
                            Label("\(idle.count) idle dev server(s) holding ports", systemImage: "moon.zzz").font(.callout).foregroundStyle(Theme.warn)
                        }
                    }
                    Panel("Storage", icon: "externaldrive") {
                        ForEach(s.disk.volumes.prefix(3)) { v in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(v.name); Spacer(); Text("\(Fmt.bytes(v.free)) free").foregroundStyle(.secondary).monospacedDigit() }.font(.callout)
                                Meter(value: v.usedFraction, color: Theme.level(v.usedFraction, base: Theme.color(.diskRead)))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct GaugeTile: View {
    @EnvironmentObject var model: AppModel
    var title: LocalizedStringKey
    var value: Double
    var text: String
    var sub: String
    var color: Color
    var section: Section
    var body: some View {
        Button { model.selection = section } label: {
            Panel {
                HStack(spacing: 14) {
                    ZStack {
                        Ring(value: value, color: color, lineWidth: 8)
                        Text(Fmt.percent(value)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(text).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CPU

struct CPUView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "CPU", subtitle: "\(s.chip) · \(s.cpu.cores.count) cores (\(s.cpu.cores.filter { !$0.isEfficiency }.count) performance, \(s.cpu.cores.filter(\.isEfficiency).count) efficiency)")
            Panel("Usage", icon: "waveform.path.ecg") {
                HStack(alignment: .top, spacing: 24) {
                    BigNumber(value: Fmt.percent(s.cpu.total), caption: "Total", color: Theme.level(s.cpu.total, base: .primary))
                    FigureGrid(items: [("User", Fmt.percent(s.cpu.user), Theme.color(.cpu)), ("System", Fmt.percent(s.cpu.system), Theme.color(.memory)),
                                       ("Idle", Fmt.percent(s.cpu.idle), nil), ("Load 1 min", String(format: "%.2f", s.cpu.load1), nil),
                                       ("Load 5 min", String(format: "%.2f", s.cpu.load5), nil), ("Load 15 min", String(format: "%.2f", s.cpu.load15), nil)], columns: 3)
                }
                ZStack {
                    Sparkline(values: model.series["cpu"]?.values ?? [], color: Theme.color(.memory), maxValue: 1, capacity: 150)
                    Sparkline(values: model.series["cpu_user"]?.values ?? [], color: Theme.color(.cpu), maxValue: 1, capacity: 150)
                }
                .frame(height: 110)
                if s.power.available { Text("CPU power \(Fmt.watts(s.power.cpuWatts))").font(.caption).foregroundStyle(.secondary) }
            }
            Panel("Cores", icon: "square.grid.3x3") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(s.cpu.cores, id: \.index) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.isEfficiency ? "E\(c.index)" : "P\(c.index)").font(.caption2.weight(.bold)).foregroundStyle(c.isEfficiency ? .secondary : .primary)
                                Spacer()
                                Text(Fmt.percent(c.total)).font(.caption2.monospacedDigit())
                            }
                            Sparkline(values: model.coreSeries[c.index]?.values ?? [], color: c.isEfficiency ? Theme.color(.neural) : Theme.color(.cpu), maxValue: 1, capacity: 60)
                                .frame(height: 34)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            AppsBehind(sort: { $0.cpu > $1.cpu }, value: { Fmt.cpu($0.cpu, cores: model.cores) }, fraction: { $0.cpu / 100 }, color: Theme.color(.cpu), limit: 10)
        }
    }
}

// MARK: - Memory

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let m = model.snapshot.memory
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Memory", subtitle: "\(Fmt.bytes(m.total)) unified memory")
            Panel("Breakdown", icon: "memorychip") {
                HStack(alignment: .top, spacing: 24) {
                    BigNumber(value: Fmt.bytes(m.used), caption: "In use", color: m.pressureLevel >= 4 ? Theme.strain : .primary)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Pressure"); Pill(text: LocalizedStringKey(m.pressureName), color: m.pressureLevel >= 4 ? Theme.strain : m.pressureLevel >= 2 ? Theme.warn : Theme.good) }
                        Meter(value: m.pressurePercent, color: m.pressureLevel >= 4 ? Theme.strain : m.pressureLevel >= 2 ? Theme.warn : Theme.good, height: 8).frame(width: 220)
                    }
                }
                SegmentBar(segments: [Segment(label: "App", value: Double(m.app), color: Theme.color(.memory)),
                                      Segment(label: "Wired", value: Double(m.wired), color: Theme.color(.cpu)),
                                      Segment(label: "Compressed", value: Double(m.compressed), color: Theme.color(.gpu)),
                                      Segment(label: "Cached", value: Double(m.cached), color: Color.secondary.opacity(0.4))], total: Double(m.total), height: 16)
                FigureGrid(items: [("App", Fmt.bytes(m.app), Theme.color(.memory)), ("Wired", Fmt.bytes(m.wired), Theme.color(.cpu)),
                                   ("Compressed", Fmt.bytes(m.compressed), Theme.color(.gpu)), ("Cached files", Fmt.bytes(m.cached), Color.secondary.opacity(0.4)),
                                   ("Free", Fmt.bytes(m.free), nil), ("Swap used", "\(Fmt.bytes(m.swapUsed)) of \(Fmt.bytes(m.swapTotal))", nil)], columns: 3)
                Sparkline(values: model.series["mem_pressure"]?.values ?? [], color: Theme.color(.memory), maxValue: 1, capacity: 150).frame(height: 80)
                if model.snapshot.power.available, (model.series["mem_bw"]?.max ?? 0) > 0 {
                    HStack {
                        Text("Memory traffic").font(.caption).foregroundStyle(.secondary)
                        Text("read \(Fmt.rate(model.snapshot.power.memReadBps, unit: .bytes)) · write \(Fmt.rate(model.snapshot.power.memWriteBps, unit: .bytes))").font(.caption.monospacedDigit())
                    }
                }
            }
            AppsBehind(sort: { $0.memory > $1.memory }, value: { Fmt.bytes($0.memory) }, fraction: { Double($0.memory) / Double(max(m.total, 1)) * 4 }, color: Theme.color(.memory), limit: 10)
        }
    }
}

// MARK: - Disk

struct DiskView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let d = model.snapshot.disk
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Disk", subtitle: "Read \(Fmt.rate(d.readBps)) · Write \(Fmt.rate(d.writeBps))")
            Panel("Activity", icon: "arrow.up.arrow.down") {
                HStack(spacing: 24) {
                    BigNumber(value: Fmt.rate(d.readBps), caption: "Read", color: Theme.color(.diskRead))
                    BigNumber(value: Fmt.rate(d.writeBps), caption: "Write", color: Theme.color(.diskWrite))
                    FigureGrid(items: [("Reads/s", String(format: "%.0f", d.readOps), nil), ("Writes/s", String(format: "%.0f", d.writeOps), nil),
                                       ("Read since boot", Fmt.bytes(d.totalRead), nil), ("Written since boot", Fmt.bytes(d.totalWritten), nil)], columns: 2)
                }
                MirrorGraph(up: model.series["disk_read"]?.values ?? [], down: model.series["disk_write"]?.values ?? [], upColor: Theme.color(.diskRead), downColor: Theme.color(.diskWrite)).frame(height: 110)
            }
            Panel("Volumes", icon: "externaldrive") {
                ForEach(d.volumes) { v in
                    HStack(spacing: 12) {
                        Image(systemName: v.isInternal ? "internaldrive" : v.isRemovable ? "externaldrive.badge.minus" : "externaldrive").font(.title2).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(v.name).font(.headline)
                                Text(v.format).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Fmt.bytes(v.free)) free of \(Fmt.bytes(v.total))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Meter(value: v.usedFraction, color: Theme.level(v.usedFraction, base: Theme.color(.diskRead)), height: 8)
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: v.path)) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            AppsBehind(sort: { $0.diskReadBps + $0.diskWriteBps > $1.diskReadBps + $1.diskWriteBps },
                       value: { Fmt.rate($0.diskReadBps + $0.diskWriteBps) },
                       fraction: { ($0.diskReadBps + $0.diskWriteBps) / max(d.readBps + d.writeBps, 1) }, color: Theme.color(.diskWrite), limit: 8,
                       filter: { $0.diskReadBps + $0.diskWriteBps > 0 })
        }
    }
}

// MARK: - Network

struct NetworkView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let n = model.snapshot.network
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Network", subtitle: n.primaryInterface.isEmpty ? "Offline" : "Primary interface \(n.primaryInterface)")
            Panel("Throughput", icon: "arrow.down.arrow.up") {
                HStack(spacing: 24) {
                    BigNumber(value: Fmt.rate(n.inBps), caption: "Download", color: Theme.color(.networkIn))
                    BigNumber(value: Fmt.rate(n.outBps), caption: "Upload", color: Theme.color(.networkOut))
                    FigureGrid(items: [("Received since boot", Fmt.bytes(n.totalIn), nil), ("Sent since boot", Fmt.bytes(n.totalOut), nil)], columns: 2)
                }
                MirrorGraph(up: model.series["net_in"]?.values ?? [], down: model.series["net_out"]?.values ?? [], upColor: Theme.color(.networkIn), downColor: Theme.color(.networkOut)).frame(height: 110)
            }
            Panel("Interfaces", icon: "point.3.connected.trianglepath.dotted") {
                ForEach(n.interfaces) { i in
                    HStack {
                        Circle().fill(i.isUp ? Theme.good : Color.secondary).frame(width: 7, height: 7)
                        VStack(alignment: .leading) {
                            Text(i.displayName).font(.callout.weight(.medium))
                            if !i.addresses.isEmpty { Text(i.addresses.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Spacer()
                        Text("↓ \(Fmt.rate(i.inBps))").foregroundStyle(Theme.color(.networkIn)).frame(width: 110, alignment: .trailing)
                        Text("↑ \(Fmt.rate(i.outBps))").foregroundStyle(Theme.color(.networkOut)).frame(width: 110, alignment: .trailing)
                    }
                    .font(.callout.monospacedDigit())
                    .padding(.vertical, 2)
                }
            }
            AppsBehind(sort: { $0.netInBps + $0.netOutBps > $1.netInBps + $1.netOutBps },
                       value: { "↓\(Fmt.compactRate($0.netInBps)) ↑\(Fmt.compactRate($0.netOutBps))" },
                       fraction: { ($0.netInBps + $0.netOutBps) / max(n.inBps + n.outBps, 1) }, color: Theme.color(.networkIn), limit: 8,
                       filter: { $0.netInBps + $0.netOutBps > 0 })
        }
    }
}

// MARK: - GPU

struct GPUView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "GPU", subtitle: s.gpu.name)
            Panel("Utilization", icon: "rectangle.3.group") {
                HStack(spacing: 24) {
                    ZStack { Ring(value: s.gpu.utilization, color: Theme.color(.gpu), lineWidth: 10); Text(Fmt.percent(s.gpu.utilization)).font(.title3.weight(.bold)).monospacedDigit() }.frame(width: 90, height: 90)
                    FigureGrid(items: [("Device", Fmt.percent(s.gpu.utilization), Theme.color(.gpu)), ("Renderer", Fmt.percent(s.gpu.renderer), nil), ("Tiler", Fmt.percent(s.gpu.tiler), nil),
                                       ("Memory in use", Fmt.bytes(s.gpu.memoryInUse), nil), ("Power", s.power.available ? Fmt.watts(s.power.gpuWatts) : "—", Theme.color(.power)),
                                       ("Temperature", Fmt.temp(s.thermals.gpuC), Theme.color(.temperature))], columns: 3)
                }
                Sparkline(values: model.series["gpu"]?.values ?? [], color: Theme.color(.gpu), maxValue: 1, capacity: 150).frame(height: 110)
            }
            if s.power.available {
                Panel("GPU power", icon: "bolt") {
                    Sparkline(values: model.series["gpu_w"]?.values ?? [], color: Theme.color(.power), capacity: 150).frame(height: 70)
                }
            }
            AppsBehind(title: "Busiest apps (GPU work is attributed to the app's CPU share)", sort: { $0.energy > $1.energy }, value: { Fmt.watts($0.energy) },
                       fraction: { $0.energy / max(s.power.packageWatts, 0.1) }, color: Theme.color(.gpu), limit: 6)
        }
    }
}

// MARK: - Neural Engine

struct NeuralView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.snapshot.power
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Neural Engine", subtitle: p.available ? "Apple Neural Engine and memory traffic" : "Power counters aren't available on this Mac")
            Panel("Neural Engine", icon: "brain") {
                HStack(spacing: 24) {
                    ZStack { Ring(value: p.aneActive, color: Theme.color(.neural), lineWidth: 10); Text(p.aneWatts > 0.01 ? "Active" : "Idle").font(.callout.weight(.bold)) }.frame(width: 90, height: 90)
                    FigureGrid(items: [("ANE power", Fmt.watts(p.aneWatts), Theme.color(.neural)), ("Estimated load", Fmt.percent(p.aneActive), nil),
                                       ("Peak (session)", Fmt.watts(model.series["ane_w"]?.max ?? 0), nil)], columns: 3)
                }
                Sparkline(values: model.series["ane_w"]?.values ?? [], color: Theme.color(.neural), capacity: 150).frame(height: 90)
                Text("Used by on-device ML: Apple Intelligence, dictation, Photos, Core ML apps and local models.").font(.caption).foregroundStyle(.secondary)
            }
            Panel("Memory traffic", icon: "arrow.left.arrow.right") {
                HStack(spacing: 24) {
                    BigNumber(value: Fmt.rate(p.memReadBps, unit: .bytes), caption: "Read", color: Theme.color(.diskRead))
                    BigNumber(value: Fmt.rate(p.memWriteBps, unit: .bytes), caption: "Write", color: Theme.color(.diskWrite))
                    BigNumber(value: Fmt.watts(p.dramWatts), caption: "DRAM power")
                }
                Sparkline(values: model.series["mem_bw"]?.values ?? [], color: Theme.color(.memory), capacity: 150).frame(height: 70)
            }
            Panel("Chip power", icon: "bolt") {
                SegmentBar(segments: [Segment(label: "CPU", value: p.cpuWatts, color: Theme.color(.cpu)), Segment(label: "GPU", value: p.gpuWatts, color: Theme.color(.gpu)),
                                      Segment(label: "ANE", value: p.aneWatts, color: Theme.color(.neural)), Segment(label: "DRAM", value: p.dramWatts, color: Theme.color(.memory))],
                           total: max(p.packageWatts, 0.001), height: 14)
                FigureGrid(items: [("CPU", Fmt.watts(p.cpuWatts), Theme.color(.cpu)), ("GPU", Fmt.watts(p.gpuWatts), Theme.color(.gpu)), ("ANE", Fmt.watts(p.aneWatts), Theme.color(.neural)), ("DRAM", Fmt.watts(p.dramWatts), Theme.color(.memory))], columns: 4)
            }
        }
    }
}

// MARK: - Power & battery

struct PowerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.snapshot
        let b = s.battery
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Power & Battery", subtitle: b.present ? (b.isCharging ? "Charging" : b.isPluggedIn ? "On power adapter" : "On battery") : "This Mac has no battery")
            if b.present {
                Panel("Battery", icon: "battery.75percent") {
                    HStack(spacing: 24) {
                        ZStack { Ring(value: b.percent, color: b.percent < 0.15 ? Theme.strain : Theme.color(.battery), lineWidth: 10); Text(Fmt.percent(b.percent)).font(.title3.weight(.bold)).monospacedDigit() }.frame(width: 90, height: 90)
                        FigureGrid(items: [
                            (b.isCharging ? "Until full" : "Time remaining", b.timeRemainingMinutes.map { Fmt.duration(Double($0) * 60) } ?? "Calculating…", nil),
                            ("Power draw", b.powerDrawW > 0 ? Fmt.watts(b.powerDrawW) : (b.isCharging ? "Charging \(Fmt.watts(-b.powerDrawW))" : "—"), Theme.color(.power)),
                            ("Health", "\(Fmt.percent(b.health))\(b.condition.isEmpty ? "" : " · \(b.condition)")", nil),
                            ("Cycle count", "\(b.cycleCount)", nil), ("Temperature", Fmt.temp(b.temperatureC), nil),
                            ("Capacity", "\(b.maxCapacity) / \(b.designCapacity) mAh", nil),
                            ("Voltage", String(format: "%.2f V", b.voltage), nil), ("Adapter", b.adapterWatts > 0 ? "\(Int(b.adapterWatts)) W" : "—", nil)], columns: 3)
                    }
                    Sparkline(values: model.series["battery"]?.values ?? [], color: Theme.color(.battery), maxValue: 1, capacity: 150).frame(height: 60)
                }
            }
            if s.power.available {
                Panel("Power use", icon: "bolt") {
                    HStack(spacing: 24) {
                        if s.power.systemWatts > 0 { BigNumber(value: Fmt.watts(s.power.systemWatts), caption: "Whole system") }
                        BigNumber(value: Fmt.watts(s.power.packageWatts), caption: "Chip (CPU+GPU+ANE+DRAM)")
                    }
                    Sparkline(values: model.series["sys_w"]?.values ?? [], color: Theme.color(.power), capacity: 150).frame(height: 90)
                    FigureGrid(items: [("CPU", Fmt.watts(s.power.cpuWatts), Theme.color(.cpu)), ("GPU", Fmt.watts(s.power.gpuWatts), Theme.color(.gpu)),
                                       ("Neural Engine", Fmt.watts(s.power.aneWatts), Theme.color(.neural)), ("Memory", Fmt.watts(s.power.dramWatts), Theme.color(.memory))], columns: 4)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 14) {
                AppsBehind(title: "Drain sources", sort: { $0.energy > $1.energy }, value: { Fmt.watts($0.energy) },
                           fraction: { $0.energy / max(s.power.packageWatts, 0.1) }, color: Theme.color(.power), limit: 8)
                Panel("Keeping your Mac awake", icon: "cup.and.saucer") {
                    if model.sleepBlockers.isEmpty { Text("Nothing is preventing sleep.").foregroundStyle(.secondary).font(.callout) }
                    ForEach(model.sleepBlockers) { b in
                        HStack(alignment: .top) {
                            Image(systemName: b.type.contains("display") ? "display" : "moon.zzz").foregroundStyle(Theme.warn).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.process).font(.callout.weight(.medium))
                                Text("\(b.type) — \(b.name)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(verbatim: "\(b.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Thermals & fans

struct ThermalsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var fans = FanControl.shared
    var body: some View {
        let t = model.snapshot.thermals
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Thermals & Fans", subtitle: "Thermal state: \(t.thermalState)")
            Panel("Temperatures", icon: "thermometer.medium") {
                HStack(spacing: 24) {
                    BigNumber(value: Fmt.temp(t.cpuC), caption: "CPU average", color: t.cpuC > 95 ? Theme.strain : Theme.color(.temperature))
                    BigNumber(value: Fmt.temp(t.gpuC), caption: "GPU average")
                    BigNumber(value: Fmt.temp(t.sensors.filter { $0.group == "CPU" }.map(\.celsius).max() ?? 0), caption: "Hottest CPU sensor")
                }
                ZStack {
                    Sparkline(values: model.series["temp_cpu"]?.values ?? [], color: Theme.color(.temperature), maxValue: 110, capacity: 150)
                    Sparkline(values: model.series["temp_gpu"]?.values ?? [], color: Theme.color(.gpu), maxValue: 110, fill: false, capacity: 150)
                }
                .frame(height: 100)
            }
            if !t.fans.isEmpty {
                Panel("Fans", icon: "fan") {
                    ForEach(t.fans) { f in FanRow(fan: f, control: fans) }
                    if !fans.helperInstalled {
                        HStack {
                            Text("Manual fan control needs a small privileged helper (asks for your password once).").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Install helper…") { fans.installHelper() }
                        }
                    }
                    if let e = fans.lastError { Text(e).font(.caption).foregroundStyle(Theme.strain) }
                }
            }
            Panel("All sensors", icon: "sensor") {
                let groups = Dictionary(grouping: t.sensors, by: \.group).sorted { $0.key < $1.key }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 14) {
                    ForEach(groups, id: \.key) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey(g.key)).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            ForEach(g.value.sorted { $0.key < $1.key }) { r in
                                HStack {
                                    Text(r.key).font(.caption.monospaced())
                                    Meter(value: r.celsius / 110, color: Theme.level(r.celsius / 110, base: Theme.color(.temperature)), height: 4)
                                    Text(Fmt.temp(r.celsius)).font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct FanRow: View {
    var fan: FanInfo
    @ObservedObject var control: FanControl
    @State private var target: Double = 0
    @State private var manual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan")
                Text("Fan \(fan.index + 1)").font(.headline)
                Spacer()
                Text(verbatim: "\(Int(fan.rpm)) rpm").font(.title3.monospacedDigit().weight(.semibold))
                Text(verbatim: "(\(Int(fan.minRPM))–\(Int(fan.maxRPM)))").font(.caption).foregroundStyle(.secondary)
            }
            Meter(value: fan.fraction, color: Theme.color(.fan), height: 8)
            HStack {
                Picker("", selection: $manual) {
                    Text("Automatic").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                .disabled(!control.helperInstalled)
                .onChange(of: manual) { _, m in
                    if m { control.setFan(fan.index, rpm: max(target, fan.minRPM)) } else { control.setAuto(fan.index) }
                }
                if manual {
                    Slider(value: $target, in: fan.minRPM...max(fan.maxRPM, fan.minRPM + 1), step: 100) { editing in
                        if !editing { control.setFan(fan.index, rpm: target) }
                    }
                    Text(verbatim: "\(Int(target)) rpm").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
        }
        .onAppear { target = max(fan.targetRPM, fan.minRPM); manual = fan.isManual }
    }
}
