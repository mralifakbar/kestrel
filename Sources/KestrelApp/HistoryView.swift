import SwiftUI
import Charts
import KestrelCore

final class HistoryState: ObservableObject {
    static let shared = HistoryState()
    @Published var appID: String?
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case h1 = "1h", h6 = "6h", d1 = "24h", d7 = "7d", d30 = "30d", d90 = "90d", y1 = "1y"
    var id: String { rawValue }
    var seconds: Double {
        switch self { case .h1: 3600; case .h6: 21600; case .d1: 86400; case .d7: 604800; case .d30: 2592000; case .d90: 7776000; case .y1: 31536000 }
    }
}

struct HistoryMetric: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var label: String
    var metric: Metric
    var format: (Double) -> String

    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    static let all: [HistoryMetric] = [
        .init(key: "cpu", label: "CPU", metric: .cpu, format: { Fmt.percent($0) }),
        .init(key: "mem_used", label: "Memory used", metric: .memory, format: { Fmt.bytes($0) }),
        .init(key: "mem_pressure", label: "Memory pressure", metric: .memory, format: { Fmt.percent($0) }),
        .init(key: "swap", label: "Swap", metric: .memory, format: { Fmt.bytes($0) }),
        .init(key: "gpu", label: "GPU", metric: .gpu, format: { Fmt.percent($0) }),
        .init(key: "ane_w", label: "Neural Engine power", metric: .neural, format: { Fmt.watts($0) }),
        .init(key: "cpu_w", label: "CPU power", metric: .power, format: { Fmt.watts($0) }),
        .init(key: "gpu_w", label: "GPU power", metric: .power, format: { Fmt.watts($0) }),
        .init(key: "sys_w", label: "System power", metric: .power, format: { Fmt.watts($0) }),
        .init(key: "net_in", label: "Download", metric: .networkIn, format: { Fmt.rate($0) }),
        .init(key: "net_out", label: "Upload", metric: .networkOut, format: { Fmt.rate($0) }),
        .init(key: "disk_read", label: "Disk read", metric: .diskRead, format: { Fmt.rate($0) }),
        .init(key: "disk_write", label: "Disk write", metric: .diskWrite, format: { Fmt.rate($0) }),
        .init(key: "temp_cpu", label: "CPU temperature", metric: .temperature, format: { Fmt.temp($0) }),
        .init(key: "temp_gpu", label: "GPU temperature", metric: .temperature, format: { Fmt.temp($0) }),
        .init(key: "fan0", label: "Fan speed", metric: .fan, format: { "\(Int($0)) rpm" }),
        .init(key: "battery", label: "Battery", metric: .battery, format: { Fmt.percent($0) }),
    ]
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state = HistoryState.shared
    @State private var range: HistoryRange = .h6
    @State private var metric = HistoryMetric.all[0]
    @State private var points: [HistoryPoint] = []
    @State private var apps: [HistoryApp] = []
    @State private var appCPU: [HistoryPoint] = []
    @State private var appMem: [HistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "History", subtitle: "Recorded every minute · kept for \(KestrelPrefs.historyRetentionDays) days · \(Fmt.bytes(model.history.fileSize)) on disk")
                Picker("", selection: $range) { ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 340).labelsHidden()
            }
            Panel(accessory: {
                Picker("", selection: $metric) { ForEach(HistoryMetric.all) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 200)
            }) {
                if points.isEmpty {
                    Text("Not enough data yet. Kestrel records a point every minute while it runs.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    let color = Theme.color(metric.metric)
                    Chart(points) { p in
                        AreaMark(x: .value("Time", p.date), y: .value(metric.label, p.value))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.date), y: .value(metric.label, p.value))
                            .foregroundStyle(color).interpolationMethod(.monotone)
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(metric.format(d)) } } } }
                    .frame(height: 240)
                    let vals = points.map(\.value)
                    FigureGrid(items: [("Average", metric.format(vals.reduce(0, +) / Double(vals.count)), nil), ("Peak", metric.format(vals.max() ?? 0), nil), ("Low", metric.format(vals.min() ?? 0), nil)], columns: 3)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Panel("Apps over \(range.rawValue)", icon: "square.grid.2x2") {
                    if apps.isEmpty { Text("No app history yet.").foregroundStyle(.secondary) }
                    ForEach(apps) { a in
                        Button { state.appID = a.id } label: {
                            HStack {
                                Text(a.name).lineLimit(1)
                                Spacer()
                                Text("avg \(Fmt.cpu(a.avgCPU, cores: model.cores))").frame(width: 90, alignment: .trailing)
                                Text("peak \(Fmt.bytes(a.maxMemory))").frame(width: 110, alignment: .trailing).foregroundStyle(.secondary)
                            }
                            .font(.callout.monospacedDigit())
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(state.appID == a.id ? Color.accentColor.opacity(0.15) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(cornerRadius: 6))
                    }
                }
                .frame(width: 400)
                Panel(LocalizedStringKey(apps.first(where: { $0.id == state.appID })?.name ?? model.snapshot.apps.first(where: { $0.id == state.appID })?.name ?? "Select an app"), icon: "chart.xyaxis.line") {
                    if !appCPU.isEmpty {
                        Text("CPU").font(.caption).foregroundStyle(.secondary)
                        Chart(appCPU) { LineMark(x: .value("Time", $0.date), y: .value("CPU", $0.value)).foregroundStyle(Theme.color(.cpu)).interpolationMethod(.monotone) }
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.cpu(d, cores: model.cores)) } } } }
                            .frame(height: 120)
                        Text("Memory").font(.caption).foregroundStyle(.secondary)
                        Chart(appMem) { LineMark(x: .value("Time", $0.date), y: .value("Memory", $0.value)).foregroundStyle(Theme.color(.memory)).interpolationMethod(.monotone) }
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(d)) } } } }
                            .frame(height: 120)
                    } else {
                        Text("Pick an app to see its CPU and memory over time.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: range) { _, _ in load() }
        .onChange(of: metric) { _, _ in load() }
        .onChange(of: state.appID) { _, _ in load() }
    }

    func load() {
        let since = Date().addingTimeInterval(-range.seconds)
        let key = metric.key
        let app = state.appID
        let store = model.history
        DispatchQueue.global(qos: .userInitiated).async {
            let p = store.series(key, since: since, points: 200)
            let a = store.topApps(since: since, limit: 20)
            let s = app.map { store.appSeries($0, since: since, points: 150) }
            DispatchQueue.main.async {
                points = p; apps = a
                appCPU = s?.cpu ?? []; appMem = s?.mem ?? []
            }
        }
    }
}
