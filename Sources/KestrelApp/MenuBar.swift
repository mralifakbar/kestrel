import AppKit
import SwiftUI
import KestrelCore

enum BarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, neural, network, disk, temperature, power, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"; case .memory: "Memory"; case .gpu: "GPU"; case .neural: "Neural Engine"; case .network: "Network"
        case .disk: "Disk"; case .temperature: "Temperature"; case .power: "Power"; case .battery: "Battery"
        }
    }
    var short: String {
        switch self {
        case .cpu: "CPU"; case .memory: "MEM"; case .gpu: "GPU"; case .neural: "ANE"; case .network: "NET"
        case .disk: "DSK"; case .temperature: "TMP"; case .power: "PWR"; case .battery: "BAT"
        }
    }
    var section: Section {
        switch self {
        case .cpu: .cpu; case .memory: .memory; case .gpu: .gpu; case .neural: .neural; case .network: .network
        case .disk: .disk; case .temperature: .thermals; case .power, .battery: .power
        }
    }
    var icon: String {
        switch self {
        case .cpu: "cpu"; case .memory: "memorychip"; case .gpu: "rectangle.3.group"; case .neural: "brain"; case .network: "network"
        case .disk: "internaldrive"; case .temperature: "thermometer.medium"; case .power: "bolt"; case .battery: "battery.75percent"
        }
    }
}

enum BarStyle: String, CaseIterable, Identifiable {
    case value, graph, both
    var id: String { rawValue }
    var label: LocalizedStringKey { switch self { case .value: "Value"; case .graph: "Graph"; case .both: "Value + graph" } }
}

enum BarPrefs {
    static var enabled: [BarMetric] {
        get { (UserDefaults.standard.stringArray(forKey: "menubar.enabled") ?? ["cpu", "memory", "network"]).compactMap(BarMetric.init) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "menubar.enabled") }
    }
    static func style(_ m: BarMetric) -> BarStyle {
        BarStyle(rawValue: UserDefaults.standard.string(forKey: "menubar.style.\(m.rawValue)") ?? "") ?? (m == .cpu ? .both : .value)
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var items: [BarMetric: NSStatusItem] = [:]
    private var fallback: NSStatusItem?
    private let popover = NSPopover()
    private var popoverMetric: BarMetric?
    private var lastConfig = ""

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        rebuild()
        model.onSample = { [weak self] s in self?.update(s) }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildIfNeeded() }
        }
    }

    private var config: String {
        BarPrefs.enabled.map { "\($0.rawValue):\(BarPrefs.style($0).rawValue)" }.joined(separator: ",") + (UserDefaults.standard.string(forKey: "palette") ?? "")
    }

    private func rebuildIfNeeded() {
        if config != lastConfig { rebuild(); update(model.snapshot) }
    }

    private func rebuild() {
        lastConfig = config
        let wanted = BarPrefs.enabled
        for (m, item) in items where !wanted.contains(m) { NSStatusBar.system.removeStatusItem(item); items[m] = nil }
        // Create in reverse so the first metric ends up leftmost on first launch; ⌘-drag order is then remembered.
        for m in wanted.reversed() where items[m] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "dev.kestrel.\(m.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
            item.button?.imagePosition = .imageOnly
            items[m] = item
        }
        if wanted.isEmpty {
            if fallback == nil {
                let f = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                f.autosaveName = "dev.kestrel.main"
                f.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Kestrel")
                f.button?.target = self
                f.button?.action = #selector(clicked(_:))
                f.button?.identifier = NSUserInterfaceItemIdentifier("cpu")
                fallback = f
            }
        } else if let f = fallback {
            NSStatusBar.system.removeStatusItem(f); fallback = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let m = sender.identifier.flatMap({ BarMetric(rawValue: $0.rawValue) }) else { return }
        if popover.isShown && popoverMetric == m { popover.performClose(nil); return }
        popoverMetric = m
        let host = NSHostingController(rootView: DropdownView(metric: m, close: { [weak self] in self?.popover.performClose(nil) })
            .environmentObject(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func update(_ s: SystemSnapshot) {
        for (m, item) in items {
            guard let button = item.button else { continue }
            let r = reading(m, s)
            button.image = StatusImage.render(label: m.short, lines: r.lines, values: r.series, maxValue: r.max, style: BarPrefs.style(m), strained: r.strained, mirrored: m == .network || m == .disk, secondary: r.secondary)
            button.toolTip = "\(m.title): \(r.lines.joined(separator: " "))"
        }
    }

    struct Reading { var lines: [String]; var series: [Double]; var secondary: [Double]? = nil; var max: Double?; var strained: Bool }

    private func reading(_ m: BarMetric, _ s: SystemSnapshot) -> Reading {
        let ser = { (k: String) in Array((self.model.series[k]?.values ?? []).suffix(20)) }
        switch m {
        case .cpu: return Reading(lines: [Fmt.percent(s.cpu.total)], series: ser("cpu"), max: 1, strained: s.cpu.total >= 0.9)
        case .memory: return Reading(lines: [Fmt.percent(s.memory.usedFraction)], series: ser("mem_pressure"), max: 1, strained: s.memory.pressureLevel >= 4)
        case .gpu: return Reading(lines: [Fmt.percent(s.gpu.utilization)], series: ser("gpu"), max: 1, strained: s.gpu.utilization >= 0.95)
        case .neural: return Reading(lines: [s.power.aneWatts > 0.01 ? Fmt.watts(s.power.aneWatts) : "idle"], series: ser("ane_w"), max: nil, strained: false)
        case .network: return Reading(lines: ["↓" + Fmt.compactRate(s.network.inBps), "↑" + Fmt.compactRate(s.network.outBps)], series: ser("net_in"), secondary: ser("net_out"), max: nil, strained: false)
        case .disk: return Reading(lines: ["R " + Fmt.compactRate(s.disk.readBps), "W " + Fmt.compactRate(s.disk.writeBps)], series: ser("disk_read"), secondary: ser("disk_write"), max: nil, strained: false)
        case .temperature: return Reading(lines: [Fmt.temp(s.thermals.cpuC)], series: ser("temp_cpu"), max: 110, strained: s.thermals.cpuC >= 95)
        case .power:
            let w = s.power.systemWatts > 0 ? s.power.systemWatts : (s.battery.present ? max(s.battery.powerDrawW, 0) : s.power.packageWatts)
            return Reading(lines: [String(format: w >= 10 ? "%.0fW" : "%.1fW", w)], series: ser("sys_w"), max: nil, strained: false)
        case .battery:
            guard s.battery.present else { return Reading(lines: ["AC"], series: [], max: 1, strained: false) }
            return Reading(lines: [Fmt.percent(s.battery.percent) + (s.battery.isCharging ? "⚡︎" : "")], series: ser("battery"), max: 1, strained: s.battery.percent < 0.1 && !s.battery.isPluggedIn)
        }
    }
}

/// Draws a compact two-row status item: tiny label above the value, with an optional bar graph.
enum StatusImage {
    static func render(label: String, lines: [String], values: [Double], maxValue: Double?, style: BarStyle, strained: Bool, mirrored: Bool, secondary: [Double]?) -> NSImage {
        let h: CGFloat = 22
        let color: NSColor = strained ? NSColor(red: 0.95, green: 0.26, blue: 0.24, alpha: 1) : .black
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: lines.count > 1 ? 9 : 11, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .heavy)
        let vAttr: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: color]
        let lAttr: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color.withAlphaComponent(0.75), .kern: 0.6]
        let showText = style != .graph
        let showGraph = style != .value && !values.isEmpty
        let textW = showText ? max(lines.map { ($0 as NSString).size(withAttributes: vAttr).width }.max() ?? 0, lines.count > 1 ? 0 : (label as NSString).size(withAttributes: lAttr).width) : 0
        let graphW: CGFloat = showGraph ? 26 : 0
        let gap: CGFloat = showText && showGraph ? 4 : 0
        let width = ceil(textW + graphW + gap + 2)
        let img = NSImage(size: NSSize(width: max(width, 8), height: h), flipped: false) { _ in
            var x: CGFloat = 1
            if showText {
                if lines.count > 1 {
                    for (i, l) in lines.enumerated() {
                        (l as NSString).draw(at: NSPoint(x: x, y: i == 0 ? 11 : 1), withAttributes: vAttr)
                    }
                } else {
                    (label as NSString).draw(at: NSPoint(x: x, y: 13), withAttributes: lAttr)
                    ((lines.first ?? "") as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: vAttr)
                }
                x += textW + gap
            }
            if showGraph {
                let rect = NSRect(x: x, y: 3, width: graphW, height: h - 6)
                NSColor.black.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                let all = values + (secondary ?? [])
                let mx = max(maxValue ?? (all.max() ?? 1), 0.0001)
                let n = 13
                let bw = rect.width / CGFloat(n)
                color.setFill()
                if mirrored, let sec = secondary {
                    let mid = rect.midY
                    for (i, v) in values.suffix(n).enumerated() {
                        let bh = CGFloat(min(v / mx, 1)) * (rect.height / 2)
                        NSBezierPath(rect: NSRect(x: rect.minX + CGFloat(i + n - min(values.count, n)) * bw + 0.5, y: mid, width: bw - 1, height: max(bh, 0.5))).fill()
                    }
                    color.withAlphaComponent(0.55).setFill()
                    for (i, v) in sec.suffix(n).enumerated() {
                        let bh = CGFloat(min(v / mx, 1)) * (rect.height / 2)
                        NSBezierPath(rect: NSRect(x: rect.minX + CGFloat(i + n - min(sec.count, n)) * bw + 0.5, y: mid - max(bh, 0.5), width: bw - 1, height: max(bh, 0.5))).fill()
                    }
                } else {
                    for (i, v) in values.suffix(n).enumerated() {
                        let bh = CGFloat(min(v / mx, 1)) * rect.height
                        NSBezierPath(rect: NSRect(x: rect.minX + CGFloat(i + n - min(values.count, n)) * bw + 0.5, y: rect.minY, width: bw - 1, height: max(bh, 0.5))).fill()
                    }
                }
            }
            return true
        }
        img.isTemplate = !strained
        return img
    }
}

// MARK: - Dropdown

enum DropBlock: String, CaseIterable, Identifiable {
    case graph, figures, apps, summary
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self { case .graph: "Graph"; case .figures: "Figures"; case .apps: "Apps behind it"; case .summary: "Other readings" }
    }
    static func ordered() -> [DropBlock] {
        let hidden = Set((UserDefaults.standard.string(forKey: "dropdownHidden") ?? "").split(separator: ",").map(String.init))
        var order = (UserDefaults.standard.string(forKey: "dropdownOrder") ?? "").split(separator: ",").compactMap { DropBlock(rawValue: String($0)) }
        for b in allCases where !order.contains(b) { order.append(b) }
        return order.filter { !hidden.contains($0.rawValue) }
    }
}

struct DropdownView: View {
    @EnvironmentObject var model: AppModel
    var metric: BarMetric
    var close: () -> Void

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: metric.icon).font(.title3).foregroundStyle(accent)
                Text(metric.title).font(.headline)
                Spacer()
                Text(headline(s)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().tracking(-0.3)
                    
            }
            ForEach(DropBlock.ordered()) { block in
                switch block {
                case .graph: graph.frame(height: 56)
                case .figures: FigureGrid(items: figures(s), columns: 3)
                case .apps: apps(s)
                case .summary: summary(s)
                }
            }
            Divider()
            HStack {
                Button { close(); model.open(section: metric.section) } label: { Label("Open Kestrel", systemImage: "macwindow") }
                Spacer()
                Button { close(); WindowOpener.openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Kestrel")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    var accent: Color {
        switch metric {
        case .cpu: Theme.color(.cpu); case .memory: Theme.color(.memory); case .gpu: Theme.color(.gpu); case .neural: Theme.color(.neural)
        case .network: Theme.color(.networkIn); case .disk: Theme.color(.diskRead); case .temperature: Theme.color(.temperature)
        case .power: Theme.color(.power); case .battery: Theme.color(.battery)
        }
    }

    @ViewBuilder var graph: some View {
        let v = { (k: String) in model.series[k]?.values ?? [] }
        switch metric {
        case .cpu: Sparkline(values: v("cpu"), color: accent, maxValue: 1, capacity: 150)
        case .memory: Sparkline(values: v("mem_pressure"), color: accent, maxValue: 1, capacity: 150)
        case .gpu: Sparkline(values: v("gpu"), color: accent, maxValue: 1, capacity: 150)
        case .neural: Sparkline(values: v("ane_w"), color: accent, capacity: 150)
        case .network: MirrorGraph(up: v("net_in"), down: v("net_out"), upColor: Theme.color(.networkIn), downColor: Theme.color(.networkOut))
        case .disk: MirrorGraph(up: v("disk_read"), down: v("disk_write"), upColor: Theme.color(.diskRead), downColor: Theme.color(.diskWrite))
        case .temperature: Sparkline(values: v("temp_cpu"), color: accent, maxValue: 110, capacity: 150)
        case .power: Sparkline(values: v("sys_w"), color: accent, capacity: 150)
        case .battery: Sparkline(values: v("battery"), color: accent, maxValue: 1, capacity: 150)
        }
    }

    func headline(_ s: SystemSnapshot) -> String {
        switch metric {
        case .cpu: Fmt.percent(s.cpu.total)
        case .memory: Fmt.bytes(s.memory.used)
        case .gpu: Fmt.percent(s.gpu.utilization)
        case .neural: Fmt.watts(s.power.aneWatts)
        case .network: "↓\(Fmt.compactRate(s.network.inBps)) ↑\(Fmt.compactRate(s.network.outBps))"
        case .disk: "R \(Fmt.compactRate(s.disk.readBps)) W \(Fmt.compactRate(s.disk.writeBps))"
        case .temperature: Fmt.temp(s.thermals.cpuC)
        case .power: Fmt.watts(s.power.systemWatts > 0 ? s.power.systemWatts : s.power.packageWatts)
        case .battery: s.battery.present ? Fmt.percent(s.battery.percent) : "AC power"
        }
    }

    func figures(_ s: SystemSnapshot) -> [(LocalizedStringKey, String, Color?)] {
        switch metric {
        case .cpu: return [("User", Fmt.percent(s.cpu.user), Theme.color(.cpu)), ("System", Fmt.percent(s.cpu.system), Theme.color(.memory)), ("Idle", Fmt.percent(s.cpu.idle), nil),
                           ("Load 1m", String(format: "%.2f", s.cpu.load1), nil), ("Load 5m", String(format: "%.2f", s.cpu.load5), nil), ("Load 15m", String(format: "%.2f", s.cpu.load15), nil)]
        case .memory: return [("App", Fmt.bytes(s.memory.app), nil), ("Wired", Fmt.bytes(s.memory.wired), nil), ("Compressed", Fmt.bytes(s.memory.compressed), nil),
                              ("Cached", Fmt.bytes(s.memory.cached), nil), ("Swap", Fmt.bytes(s.memory.swapUsed), nil), ("Pressure", s.memory.pressureName, nil)]
        case .gpu: return [("Renderer", Fmt.percent(s.gpu.renderer), nil), ("Tiler", Fmt.percent(s.gpu.tiler), nil), ("Memory", Fmt.bytes(s.gpu.memoryInUse), nil),
                           ("Power", Fmt.watts(s.power.gpuWatts), nil), ("Temp", Fmt.temp(s.thermals.gpuC), nil)]
        case .neural: return [("ANE", Fmt.watts(s.power.aneWatts), nil), ("Mem read", Fmt.rate(s.power.memReadBps, unit: .bytes), nil), ("Mem write", Fmt.rate(s.power.memWriteBps, unit: .bytes), nil)]
        case .network: return [("Download", Fmt.rate(s.network.inBps), Theme.color(.networkIn)), ("Upload", Fmt.rate(s.network.outBps), Theme.color(.networkOut)), ("Interface", s.network.primaryInterface, nil),
                               ("Received", Fmt.bytes(s.network.totalIn), nil), ("Sent", Fmt.bytes(s.network.totalOut), nil)]
        case .disk: return [("Read", Fmt.rate(s.disk.readBps), Theme.color(.diskRead)), ("Write", Fmt.rate(s.disk.writeBps), Theme.color(.diskWrite))]
            + s.disk.volumes.prefix(1).map { (LocalizedStringKey("Free on \($0.name)"), Fmt.bytes($0.free), nil) }
        case .temperature: return [("CPU", Fmt.temp(s.thermals.cpuC), nil), ("GPU", Fmt.temp(s.thermals.gpuC), nil), ("State", s.thermals.thermalState, nil)]
            + s.thermals.fans.map { (LocalizedStringKey("Fan \($0.index + 1)"), "\(Int($0.rpm)) rpm", nil) }
        case .power: return [("CPU", Fmt.watts(s.power.cpuWatts), nil), ("GPU", Fmt.watts(s.power.gpuWatts), nil), ("ANE", Fmt.watts(s.power.aneWatts), nil),
                             ("DRAM", Fmt.watts(s.power.dramWatts), nil), ("System", s.power.systemWatts > 0 ? Fmt.watts(s.power.systemWatts) : "—", nil)]
        case .battery:
            let b = s.battery
            guard b.present else { return [("Source", "Power adapter", nil)] }
            return [("Time", b.timeRemainingMinutes.map { Fmt.duration(Double($0) * 60) } ?? "—", nil), ("Draw", Fmt.watts(max(b.powerDrawW, 0)), nil), ("Health", Fmt.percent(b.health), nil),
                    ("Cycles", "\(b.cycleCount)", nil), ("Temp", Fmt.temp(b.temperatureC), nil), ("Charging", b.isCharging ? "Yes" : "No", nil)]
        }
    }

    @ViewBuilder func apps(_ s: SystemSnapshot) -> some View {
        let list: [(AppUsage, String)] = {
            switch metric {
            case .memory: return s.apps.sorted { $0.memory > $1.memory }.prefix(5).map { ($0, Fmt.bytes($0.memory)) }
            case .network: return s.apps.filter { $0.netTotal > 0 }.sorted { $0.netTotal > $1.netTotal }.prefix(5).map { ($0, Fmt.rate($0.netTotal)) }
            case .disk: return s.apps.filter { $0.diskTotal > 0 }.sorted { $0.diskTotal > $1.diskTotal }.prefix(5).map { ($0, Fmt.rate($0.diskTotal)) }
            case .power, .battery, .gpu, .neural: return s.apps.sorted { $0.energy > $1.energy }.prefix(5).map { ($0, Fmt.watts($0.energy)) }
            default: return s.apps.prefix(5).map { ($0, Fmt.cpu($0.cpu, cores: s.cpu.coreCount)) }
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            Text("Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(list, id: \.0.id) { a, v in
                Button { close(); model.open(section: .apps, app: a.id) } label: {
                    HStack {
                        AppIcon(path: a.bundlePath, system: a.isSystem, size: 16)
                        Text(a.name).lineLimit(1)
                        Spacer()
                        Text(v).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(cornerRadius: 6))
            }
        }
    }

    func summary(_ s: SystemSnapshot) -> some View {
        HStack(spacing: 10) {
            mini("CPU", Fmt.percent(s.cpu.total))
            mini("MEM", Fmt.percent(s.memory.usedFraction))
            mini("GPU", Fmt.percent(s.gpu.utilization))
            mini("TEMP", Fmt.temp(s.thermals.cpuC))
        }
    }

    func mini(_ l: String, _ v: String) -> some View {
        VStack(spacing: 1) {
            Text(l).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(v).font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}
