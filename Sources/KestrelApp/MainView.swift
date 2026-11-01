import SwiftUI
import KestrelCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("sectionOrder") private var sectionOrder = ""
    @AppStorage("hiddenSections") private var hiddenSections = ""
    @AppStorage("compact") private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var visibleSections: [Section] { LayoutPrefs.windowSections(order: sectionOrder, hidden: hiddenSections) }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(groups, id: \.self) { g in
                    SwiftUI.Section(LocalizedStringKey(g)) {
                        ForEach(visibleSections.filter { $0.group == g }) { s in
                            SidebarRow(section: s).tag(s)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            // Content scrolls underneath the translucent strip of live readings.
            ScrollView {
                detail(for: model.selection ?? .overview)
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(model.selection)
            .transition(.opacity)
            .animation(reduceMotion ? nil : Motion.fade, value: model.selection)
            .safeAreaInset(edge: .top, spacing: 0) { LiveStrip() }
            .navigationTitle((model.selection ?? .overview).plainTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareMenu()
                    Button { WindowOpener.openSettings() } label: { Image(systemName: "slider.horizontal.3") }.help("Settings")
                }
            }
        }
        .onChange(of: model.selection) { _, new in
            if let new { model.activeSection = new; model.refreshSlow(force: false) }
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for s in visibleSections where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    @ViewBuilder
    func detail(for s: Section) -> some View {
        switch s {
        case .overview: OverviewView()
        case .apps: AppsView()
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .disk: DiskView()
        case .network: NetworkView()
        case .gpu: GPUView()
        case .neural: NeuralView()
        case .power: PowerView()
        case .thermals: ThermalsView()
        case .sound: SoundView()
        case .bluetooth: BluetoothView()
        case .projects: ProjectsView()
        case .agents: AgentsView()
        case .containers: ContainersView()
        case .history: HistoryView()
        }
    }
}

enum LayoutPrefs {
    static func windowSections(order: String, hidden: String) -> [Section] {
        let hiddenSet = Set(hidden.split(separator: ",").map(String.init))
        var ordered = order.split(separator: ",").compactMap { Section(rawValue: String($0)) }
        for s in Section.allCases where !ordered.contains(s) { ordered.append(s) }
        return ordered.filter { !hiddenSet.contains($0.rawValue) }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    var section: Section

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.icon)
            Spacer()
            if let badge { Text(badge).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    var badge: String? {
        let s = model.snapshot
        switch section {
        case .cpu: return Fmt.percent(s.cpu.total)
        case .memory: return Fmt.percent(s.memory.usedFraction)
        case .gpu: return Fmt.percent(s.gpu.utilization)
        case .network: return Fmt.compactRate(s.network.inBps + s.network.outBps)
        case .thermals: return s.thermals.cpuC > 0 ? Fmt.temp(s.thermals.cpuC) : nil
        case .power: return s.battery.present ? Fmt.percent(s.battery.percent) : (s.power.systemWatts > 0 ? Fmt.watts(s.power.systemWatts) : nil)
        case .apps: return "\(s.apps.count)"
        case .projects: return model.holders.isEmpty ? nil : "\(model.holders.count)"
        case .agents: return model.agents.isEmpty ? nil : "\(model.agents.count)"
        case .containers: let n = model.containers.filter { $0.state == "running" }.count; return n == 0 ? nil : "\(n)"
        default: return nil
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.snapshot.model.isEmpty ? "Mac" : model.snapshot.model).font(.caption.weight(.semibold))
            Text("\(model.snapshot.chip) · up \(Fmt.duration(model.snapshot.uptime))").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// Always-visible strip of live readings along the top of the window.
struct LiveStrip: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        let s = model.snapshot
        HStack(spacing: 0) {
            chip(.cpu, "CPU", Fmt.percent(s.cpu.total), model.series["cpu"]?.values ?? [], Theme.color(.cpu), 1, strained: s.cpu.total > 0.9)
            chip(.memory, "MEM", Fmt.percent(s.memory.usedFraction), model.series["mem"]?.values ?? [], Theme.color(.memory), 1, strained: s.memory.pressureLevel >= 4)
            chip(.gpu, "GPU", Fmt.percent(s.gpu.utilization), model.series["gpu"]?.values ?? [], Theme.color(.gpu), 1, strained: s.gpu.utilization > 0.95)
            chip(.network, "NET", "↓\(Fmt.compactRate(s.network.inBps)) ↑\(Fmt.compactRate(s.network.outBps))", model.series["net_in"]?.values ?? [], Theme.color(.networkIn), nil, strained: false)
            chip(.disk, "DISK", "R \(Fmt.compactRate(s.disk.readBps)) W \(Fmt.compactRate(s.disk.writeBps))", model.series["disk_read"]?.values ?? [], Theme.color(.diskRead), nil, strained: false)
            if s.thermals.cpuC > 0 {
                chip(.thermals, "TEMP", Fmt.temp(s.thermals.cpuC), model.series["temp_cpu"]?.values ?? [], Theme.color(.temperature), 110, strained: s.thermals.cpuC > 95)
            }
            if s.power.available {
                chip(.power, "POWER", Fmt.watts(s.power.systemWatts > 0 ? s.power.systemWatts : s.power.packageWatts), model.series["sys_w"]?.values ?? [], Theme.color(.power), nil, strained: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .bottom) {
            // A soft edge instead of a hard divider.
            LinearGradient(colors: [Color.primary.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 6).offset(y: 6).allowsHitTesting(false)
        }
    }

    func chip(_ section: Section, _ label: String, _ value: String, _ values: [Double], _ color: Color, _ maxV: Double?, strained: Bool) -> some View {
        Button { model.selection = section } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)

                        .foregroundStyle(strained ? Theme.strain : .primary)
                        .fixedSize()
                }
                Sparkline(values: Array(values.suffix(40)), color: strained ? Theme.strain : color, maxValue: maxV, lineWidth: 1.2, capacity: 40)
                    .frame(minWidth: 18, maxWidth: 44).frame(height: 20)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.selection == section ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity)
    }
}

/// Lists apps sorted by a metric, used at the bottom of every hardware section.
struct AppsBehind: View {
    @EnvironmentObject var model: AppModel
    var title: LocalizedStringKey = "Apps behind it"
    var sort: (AppUsage, AppUsage) -> Bool
    var value: (AppUsage) -> String
    var fraction: (AppUsage) -> Double
    var color: Color
    var limit = 8
    var filter: (AppUsage) -> Bool = { _ in true }

    var body: some View {
        Panel(title, icon: "square.grid.2x2") {
            let apps = Array(model.snapshot.apps.filter(filter).sorted(by: sort).prefix(limit))
            if apps.isEmpty { Text("Nothing notable right now.").foregroundStyle(.secondary).font(.callout) }
            VStack(spacing: 6) {
                ForEach(apps) { a in
                    Button { model.selectedAppID = a.id; model.selection = .apps } label: {
                        HStack(spacing: 10) {
                            AppIcon(path: a.bundlePath, system: a.isSystem, size: 20)
                            Text(a.name).lineLimit(1)
                            if a.processCount > 1 { Text("\(a.processCount)").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(Capsule().fill(Color.primary.opacity(0.06))) }
                            Spacer()
                            Meter(value: fraction(a), color: color, height: 5).frame(width: 90)
                            Text(value(a)).monospacedDigit().frame(width: 84, alignment: .trailing)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(cornerRadius: 6))
                }
            }
        }
    }
}

struct SectionHeader: View {
    var title: LocalizedStringKey
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded)).tracking(-0.4)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
