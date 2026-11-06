import SwiftUI
import UniformTypeIdentifiers
import KestrelCore

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showSystem = true
    @State private var sortOrder = [KeyPathComparator(\AppUsage.cpu, order: .reverse)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var rows: [AppUsage] {
        model.snapshot.apps
            .filter { showSystem || !$0.isSystem }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "Apps", subtitle: "\(model.snapshot.apps.count) apps from \(model.snapshot.processes.count) processes — helpers are folded into the app that launched them")
                Toggle("macOS services", isOn: $showSystem).toggleStyle(.switch).controlSize(.small)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            HStack(alignment: .top, spacing: 14) {
                Table(rows, selection: $model.selectedAppID, sortOrder: $sortOrder) {
                    TableColumn("App", value: \.name) { a in
                        HStack(spacing: 8) {
                            AppIcon(path: a.bundlePath, system: a.isSystem, size: 18)
                            Text(a.name).lineLimit(1)
                            if a.processCount > 1 { Text("\(a.processCount)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn("CPU", value: \.cpu) { a in
                        HStack(spacing: 6) {
                            Sparkline(values: model.appSeries[a.id]?.values.suffix(30).map { $0 } ?? [], color: Theme.color(.cpu), fill: false, lineWidth: 1, capacity: 30).frame(width: 36, height: 14)
                            Text(Fmt.cpu(a.cpu, cores: model.cores)).monospacedDigit().foregroundStyle(a.cpu > 100 ? Theme.strain : .primary)
                        }
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("Memory", value: \.memory) { a in Text(Fmt.bytes(a.memory)).monospacedDigit() }.width(min: 70, ideal: 80)
                    TableColumn("Disk", value: \.diskTotal) { a in Text(a.diskTotal > 0 ? Fmt.compactRate(a.diskTotal) + "/s" : "–").monospacedDigit().foregroundStyle(.secondary) }.width(min: 60, ideal: 70)
                    TableColumn("Network", value: \.netTotal) { a in Text(a.netTotal > 0 ? Fmt.compactRate(a.netTotal) + "/s" : "–").monospacedDigit().foregroundStyle(.secondary) }.width(min: 60, ideal: 70)
                    TableColumn("Energy", value: \.energy) { a in Text(a.energy > 0.005 ? Fmt.watts(a.energy) : "–").monospacedDigit().foregroundStyle(.secondary) }.width(min: 60, ideal: 70)
                    TableColumn("Threads", value: \.threads) { a in Text(verbatim: "\(a.threads)").monospacedDigit().foregroundStyle(.secondary) }.width(min: 50, ideal: 56)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let a = model.snapshot.apps.first(where: { $0.id == id }) { AppActions(app: a) }
                }
                .frame(minHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))

                if let id = model.selectedAppID, let app = model.snapshot.apps.first(where: { $0.id == id }) {
                    // Enters from the trailing edge and leaves the same way.
                    AppDetailPanel(app: app).frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? Motion.fade : Motion.panel, value: model.selectedAppID)
        }
        .sheet(item: Binding(get: { model.inspectedPID.map { PIDBox(pid: $0) } }, set: { model.inspectedPID = $0?.pid })) { box in
            ProcessInspectorSheet(pid: box.pid)
        }
    }
}

struct PIDBox: Identifiable { var pid: Int32; var id: Int32 { pid } }

extension AppUsage {
    var diskTotal: Double { diskReadBps + diskWriteBps }
    var netTotal: Double { netInBps + netOutBps }
}

struct AppActions: View {
    var app: AppUsage
    var body: some View {
        Button("Quit \(app.name)") { Confirm.quit(pids: app.pids, name: app.name, force: false) }.disabled(app.isSystem)
        Button("Force Quit \(app.name)") { Confirm.quit(pids: app.pids, name: app.name, force: true) }.disabled(app.isSystem)
        Divider()
        Button("Inspect main process") { AppModel.shared.inspectedPID = app.mainPID }
        if let p = app.bundlePath { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
    }
}

struct AppDetailPanel: View {
    @EnvironmentObject var model: AppModel
    var app: AppUsage
    @State private var range = 0

    var members: [ProcessUsage] {
        model.snapshot.processes.filter { $0.groupID == app.id }.sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                AppIcon(path: app.bundlePath, system: app.isSystem, size: 38)
                VStack(alignment: .leading) {
                    Text(app.name).font(.headline)
                    Text(app.bundleID ?? (app.isSystem ? "Background services" : "Command-line processes")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu { AppActions(app: app) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                Button { model.selectedAppID = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Close").keyboardShortcut(.cancelAction)
            }
            FigureGrid(items: [("CPU", Fmt.cpu(app.cpu, cores: model.cores), Theme.color(.cpu)), ("Memory", Fmt.bytes(app.memory), Theme.color(.memory)),
                               ("Processes", "\(app.processCount)", nil), ("Disk", Fmt.rate(app.diskTotal), Theme.color(.diskRead)),
                               ("Network", Fmt.rate(app.netTotal), Theme.color(.networkIn)), ("Energy", Fmt.watts(app.energy), Theme.color(.power))], columns: 3)
            Sparkline(values: model.appSeries[app.id]?.values ?? [], color: Theme.color(.cpu), capacity: 120).frame(height: 60)
            HStack {
                Button("Quit") { Confirm.quit(pids: app.pids, name: app.name, force: false) }.disabled(app.isSystem)
                Button("Force Quit") { Confirm.quit(pids: app.pids, name: app.name, force: true) }.disabled(app.isSystem)
                Spacer()
                Button("History") { model.selection = .history; HistoryState.shared.appID = app.id }
            }
            Divider()
            Text("Processes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(members) { p in
                        Button { model.inspectedPID = p.pid } label: {
                            HStack {
                                Text(p.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.cpu(p.cpu, cores: model.cores)).frame(width: 52, alignment: .trailing)
                                Text(Fmt.bytes(p.memory)).frame(width: 66, alignment: .trailing).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(cornerRadius: 5))
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

// MARK: - Process inspector

struct ProcessInspectorSheet: View {
    var pid: Int32
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ProcessDetail?
    @State private var loading = true
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = detail {
                HStack(spacing: 12) {
                    AppIcon(path: AppPathHelper.app(for: d.path), size: 40)
                    VStack(alignment: .leading) {
                        Text(d.name).font(.title2.weight(.semibold))
                        Text(verbatim: "PID \(d.pid) · \(d.user)").foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    SignatureBadge(sig: d.signature)
                }
                Picker("", selection: $tab) {
                    Text("Overview").tag(0)
                    Text("Open files (\(d.openFiles.count))").tag(1)
                    Text("Network (\(d.sockets.count))").tag(2)
                    Text("Children (\(d.children.count))").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
                ScrollView {
                    switch tab {
                    case 0: overview(d)
                    case 1: list(d.openFiles)
                    case 2: sockets(d)
                    default: children(d)
                    }
                }
                .frame(minHeight: 300)
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.asText, forType: .string) }
                    Button("Save CSV…") { saveCSV(d) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)]) }.disabled(d.path.isEmpty)
                    Spacer()
                    Button("Quit") { Confirm.quit(pids: [d.pid], name: d.name, force: false); reload() }
                    Button("Force Quit") { Confirm.quit(pids: [d.pid], name: d.name, force: true); reload() }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Text("This process has exited.").frame(maxWidth: .infinity, minHeight: 200)
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .onAppear(perform: reload)
    }

    func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let d = ProcessInspector.detail(pid: pid)
            DispatchQueue.main.async { detail = d; loading = false }
        }
    }

    func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    func overview(_ d: ProcessDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Path", d.path.isEmpty ? "—" : d.path)
            row("Command line", d.arguments.joined(separator: " "))
            row("Working directory", d.workingDirectory ?? "—")
            row("Parent", "\(d.parentName) (\(d.parentPID))")
            row("Responsible process", d.responsiblePID == d.pid ? "Itself" : "\(ProcessNames.name(d.responsiblePID)) (\(d.responsiblePID))")
            row("Launch agent", d.launchAgent ?? (d.parentPID == 1 ? "Started by launchd" : "—"))
            row("Started", d.started.map { $0.formatted(date: .abbreviated, time: .standard) + " (\(Fmt.duration(-$0.timeIntervalSinceNow)) ago)" } ?? "—")
            Divider()
            row("CPU time", String(format: "%.2fs user · %.2fs system", d.userTime, d.systemTime))
            HStack(alignment: .center) {
                Text("Memory").foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Meter(value: Double(d.memory) / Double(max(d.peakMemory, 1)), color: Theme.color(.memory), height: 8).frame(width: 160)
                Text("\(Fmt.bytes(d.memory)) now · peak \(Fmt.bytes(d.peakMemory))").monospacedDigit()
            }
            .font(.callout)
            row("Threads", "\(d.threads)")
            row("Disk I/O (lifetime)", "read \(Fmt.bytes(d.diskRead)) · written \(Fmt.bytes(d.diskWritten))")
            Divider()
            row("Code signature", d.signature.summary + (d.signature.identifier.map { " — \($0)" } ?? ""))
            row("Team ID", d.signature.teamID ?? "—")
            row("Certificate", d.signature.authority ?? "—")
            row("Hardened runtime", d.signature.hardenedRuntime ? "Yes" : "No")
            row("App Sandbox", d.signature.sandboxed ? "Yes" : "No")
            if !d.listeningPorts.isEmpty {
                row("Listening on", d.listeningPorts.map { "\($0.proto) \($0.localAddress):\($0.localPort)" }.joined(separator: ", "))
            }
        }
    }

    func list(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if items.isEmpty { Text("No open files visible (other users' processes need extra privileges).").foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func sockets(_ d: ProcessDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if d.sockets.isEmpty { Text("No network sockets.").foregroundStyle(.secondary) }
            ForEach(d.sockets) { s in
                HStack {
                    Text(s.proto).frame(width: 36, alignment: .leading)
                    Text("\(s.localAddress):\(s.localPort)").frame(width: 200, alignment: .leading)
                    Text(s.remotePort > 0 ? "→ \(s.remoteAddress):\(s.remotePort)" : "").frame(width: 240, alignment: .leading)
                    Text(s.state).foregroundStyle(s.state == "LISTEN" ? Theme.good : .secondary)
                }
                .font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func children(_ d: ProcessDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if d.children.isEmpty { Text("No child processes.").foregroundStyle(.secondary) }
            ForEach(d.children) { c in
                HStack {
                    Text(verbatim: "\(c.pid)").font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
                    Text(c.name)
                    Spacer()
                    Button("Quit") { Confirm.quit(pids: [c.pid], name: c.name, force: false, tree: true); reload() }.controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func saveCSV(_ d: ProcessDetail) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "\(d.name)-\(d.pid).csv"
        if p.runModal() == .OK, let url = p.url { try? d.asCSV.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct SignatureBadge: View {
    var sig: CodeSignatureInfo
    var body: some View {
        let (text, color, icon): (String, Color, String) = !sig.signed ? ("Unsigned", Theme.strain, "exclamationmark.shield") :
            sig.isApple ? ("Apple", Theme.good, "checkmark.shield") : sig.teamID != nil ? ("Team \(sig.teamID!)", Theme.color(.cpu), "checkmark.shield") : ("Ad-hoc", Theme.warn, "shield")
        Label(text, systemImage: icon).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }
}

enum AppPathHelper {
    static func app(for path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.isEmpty ? nil : path }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
