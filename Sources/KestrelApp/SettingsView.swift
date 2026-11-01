import SwiftUI
import KestrelCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            LayoutSettings().tabItem { Label("Layout", systemImage: "sidebar.left") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "bell") }
            IntegrationSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            HistorySettings().tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 600, height: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("palette") private var palette = Palette.colorful.rawValue
    @AppStorage("compact") private var compact = false
    @AppStorage("fastInterval") private var fastInterval = 1.0
    @AppStorage("tempUnit", store: KestrelPrefs.shared) private var tempUnit = TempUnit.celsius.rawValue
    @AppStorage("rateUnit", store: KestrelPrefs.shared) private var rateUnit = RateUnit.bytes.rawValue
    @AppStorage("cpuScale", store: KestrelPrefs.shared) private var cpuScale = CPUScale.perCore.rawValue
    @State private var login = LoginItem.isEnabled

    var body: some View {
        Form {
            SwiftUI.Section("App") {
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, v in NSApp.setActivationPolicy(v ? .regular : .accessory); if v { WindowOpener.openMain() } }
                Toggle("Open at login", isOn: $login).onChange(of: login) { _, v in LoginItem.set(v) }
                Picker("Refresh while window is open", selection: $fastInterval) {
                    Text("Every second").tag(1.0); Text("Every 2 seconds").tag(2.0); Text("Every 3 seconds").tag(3.0)
                }
                .onChange(of: fastInterval) { _, _ in AppModel.shared.reschedule() }
                Text("With the window closed Kestrel samples every 5 seconds.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Units") {
                Picker("Temperature", selection: $tempUnit) { Text("Celsius").tag("celsius"); Text("Fahrenheit").tag("fahrenheit") }
                Picker("Transfer rates", selection: $rateUnit) { Text("Bytes (MB/s)").tag("bytes"); Text("Bits (Mbps)").tag("bits") }
                Picker("CPU percentages", selection: $cpuScale) { Text("Per core (100% = one core)").tag("perCore"); Text("Per Mac (100% = all cores)").tag("perMac") }
            }
            SwiftUI.Section("Appearance") {
                Picker("Colors", selection: $palette) { ForEach(Palette.allCases) { Text($0.label).tag($0.rawValue) } }
                Toggle("Compact layout", isOn: $compact)
                Text("Language follows your Mac (System Settings → General → Language & Region).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarSettings: View {
    @State private var enabled = BarPrefs.enabled
    @State private var styles: [BarMetric: BarStyle] = Dictionary(uniqueKeysWithValues: BarMetric.allCases.map { ($0, BarPrefs.style($0)) })

    var body: some View {
        Form {
            SwiftUI.Section {
                ForEach(BarMetric.allCases) { m in
                    HStack {
                        Toggle(isOn: Binding(get: { enabled.contains(m) }, set: { on in
                            if on { enabled.append(m) } else { enabled.removeAll { $0 == m } }
                            BarPrefs.enabled = enabled
                        })) { Label(m.title, systemImage: m.icon) }
                        Spacer()
                        Picker("", selection: Binding(get: { styles[m] ?? .value }, set: { styles[m] = $0; UserDefaults.standard.set($0.rawValue, forKey: "menubar.style.\(m.rawValue)") })) {
                            ForEach(BarStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 150).disabled(!enabled.contains(m))
                    }
                }
            } header: { Text("Items") } footer: {
                Text("Each reading is its own menu bar item and turns red when under strain. Hold ⌘ and drag items in the menu bar to reorder them.")
            }
        }
        .formStyle(.grouped)
    }
}

struct LayoutSettings: View {
    @AppStorage("sectionOrder") private var sectionOrder = ""
    @AppStorage("hiddenSections") private var hiddenSections = ""
    @AppStorage("dropdownOrder") private var dropdownOrder = ""
    @AppStorage("dropdownHidden") private var dropdownHidden = ""

    var sections: [Section] {
        var o = sectionOrder.split(separator: ",").compactMap { Section(rawValue: String($0)) }
        for s in Section.allCases where !o.contains(s) { o.append(s) }
        return o
    }
    var blocks: [DropBlock] {
        var o = dropdownOrder.split(separator: ",").compactMap { DropBlock(rawValue: String($0)) }
        for b in DropBlock.allCases where !o.contains(b) { o.append(b) }
        return o
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                Text("Window sections").font(.headline)
                Text("Drag to reorder, untick to hide.").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(sections) { s in
                        Toggle(isOn: Binding(get: { !hidden(hiddenSections).contains(s.rawValue) }, set: { hiddenSections = toggle(hiddenSections, s.rawValue, show: $0) })) {
                            Label(s.title, systemImage: s.icon)
                        }
                    }
                    .onMove { from, to in var a = sections; a.move(fromOffsets: from, toOffset: to); sectionOrder = a.map(\.rawValue).joined(separator: ",") }
                }
                .listStyle(.bordered)
            }
            VStack(alignment: .leading) {
                Text("Menu bar dropdown").font(.headline)
                Text("Drag to reorder, untick to hide.").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(blocks) { b in
                        Toggle(b.label, isOn: Binding(get: { !hidden(dropdownHidden).contains(b.rawValue) }, set: { dropdownHidden = toggle(dropdownHidden, b.rawValue, show: $0) }))
                    }
                    .onMove { from, to in var a = blocks; a.move(fromOffsets: from, toOffset: to); dropdownOrder = a.map(\.rawValue).joined(separator: ",") }
                }
                .listStyle(.bordered)
                .frame(height: 150)
                Button("Reset layout") { sectionOrder = ""; hiddenSections = ""; dropdownOrder = ""; dropdownHidden = "" }
            }
            .frame(width: 220)
        }
        .padding(20)
    }

    func hidden(_ s: String) -> Set<String> { Set(s.split(separator: ",").map(String.init)) }
    func toggle(_ s: String, _ key: String, show: Bool) -> String {
        var h = hidden(s)
        if show { h.remove(key) } else { h.insert(key) }
        return h.sorted().joined(separator: ",")
    }
}

struct AlertSettings: View {
    @AppStorage("alerts.enabled") private var enabled = true
    @AppStorage("alerts.cpu") private var cpu = true
    @AppStorage("alerts.cpuPercent") private var cpuPercent = 150.0
    @AppStorage("alerts.cpuSeconds") private var cpuSeconds = 60.0
    @AppStorage("alerts.memory") private var memory = true
    @AppStorage("alerts.memoryGrowthGB") private var memoryGrowth = 2.0
    @AppStorage("alerts.disk") private var disk = true
    @AppStorage("alerts.diskMBps") private var diskMB = 100.0
    @AppStorage("alerts.diskSeconds") private var diskSeconds = 30.0
    @AppStorage("alerts.network") private var network = true
    @AppStorage("alerts.networkMBps") private var netMB = 20.0
    @AppStorage("alerts.networkSeconds") private var netSeconds = 60.0
    @AppStorage("alerts.pressure") private var pressure = true
    @AppStorage("alerts.temperature") private var temperature = false
    @AppStorage("alerts.temperatureC") private var temperatureC = 95.0

    var body: some View {
        Form {
            Toggle("Send notifications", isOn: $enabled)
            SwiftUI.Section("Apps") {
                Toggle("High CPU", isOn: $cpu)
                if cpu {
                    Stepper("Above \(Int(cpuPercent))% (of one core)", value: $cpuPercent, in: 50...800, step: 25)
                    Stepper("For \(Int(cpuSeconds)) seconds", value: $cpuSeconds, in: 10...600, step: 10)
                }
                Toggle("Memory keeps growing", isOn: $memory)
                if memory { Stepper(String(format: "Grows by %.1f GB within 10 minutes", memoryGrowth), value: $memoryGrowth, in: 0.5...16, step: 0.5) }
                Toggle("Heavy disk use", isOn: $disk)
                if disk {
                    Stepper("Above \(Int(diskMB)) MB/s", value: $diskMB, in: 10...2000, step: 10)
                    Stepper("For \(Int(diskSeconds)) seconds", value: $diskSeconds, in: 10...600, step: 10)
                }
                Toggle("Heavy network use", isOn: $network)
                if network {
                    Stepper("Above \(Int(netMB)) MB/s", value: $netMB, in: 1...1000, step: 1)
                    Stepper("For \(Int(netSeconds)) seconds", value: $netSeconds, in: 10...600, step: 10)
                }
            }
            SwiftUI.Section("System") {
                Toggle("Memory pressure turns critical", isOn: $pressure)
                Toggle("CPU temperature", isOn: $temperature)
                if temperature { Stepper("Above \(Fmt.temp(temperatureC))", value: $temperatureC, in: 70...110, step: 1) }
            }
        }
        .formStyle(.grouped)
        .disabled(false)
    }
}

struct IntegrationSettings: View {
    @AppStorage("limitsEnabled", store: KestrelPrefs.shared) private var limitsEnabled = false
    @AppStorage("mcpEnabled", store: KestrelPrefs.shared) private var mcpEnabled = false
    @AppStorage("idleServerMinutes", store: KestrelPrefs.shared) private var idleMinutes = 30
    @State private var providers = KestrelPrefs.enabledLimitProviders
    @State private var cliMessage: String?

    var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kestrel").path }

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Show AI usage limits", isOn: $limitsEnabled).onChange(of: limitsEnabled) { _, v in if v { AppModel.shared.forceRefreshLimits() } }
                if limitsEnabled {
                    ForEach([("claude", "Claude (via Claude Code login)"), ("codex", "Codex (from local session logs)"), ("copilot", "GitHub Copilot (via gh CLI)"), ("cursor", "Cursor")], id: \.0) { id, label in
                        Toggle(label, isOn: Binding(get: { providers.contains(id) }, set: { on in
                            if on { providers.insert(id) } else { providers.remove(id) }
                            KestrelPrefs.enabledLimitProviders = providers
                        }))
                        .padding(.leading, 16)
                    }
                }
            } header: { Text("Usage limits") } footer: {
                Text("Reads the sign-in your tools already store on this Mac and asks the provider for your remaining quota every 5 minutes. Off by default; nothing else leaves your Mac.")
            }
            SwiftUI.Section {
                Toggle("Enable MCP server", isOn: $mcpEnabled)
                if mcpEnabled {
                    command("claude mcp add kestrel -- '\(cliPath)' mcp")
                    command("codex mcp add kestrel -- '\(cliPath)' mcp")
                    Text("Cursor: add {\"kestrel\": {\"command\": \"\(cliPath)\", \"args\": [\"mcp\"]}} to ~/.cursor/mcp.json").font(.caption).textSelection(.enabled)
                }
            } header: { Text("MCP server") } footer: {
                Text("Lets Claude, Codex and Cursor read your Mac's health. Any request to quit something shows a confirmation here first.")
            }
            SwiftUI.Section("Command line") {
                command("'\(cliPath)' status")
                HStack {
                    Button("Install `kestrel` command") { installCLI() }
                    if let m = cliMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }
            SwiftUI.Section("Dev servers") {
                Stepper("Flag as idle after \(idleMinutes) minutes without activity", value: $idleMinutes, in: 5...240, step: 5)
            }
        }
        .formStyle(.grouped)
    }

    func command(_ c: String) -> some View {
        HStack {
            Text(c).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
        }
    }

    func installCLI() {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        for d in dirs where FileManager.default.isWritableFile(atPath: d) {
            let link = "\(d)/kestrel"
            try? FileManager.default.removeItem(atPath: link)
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cliPath)
                cliMessage = "Linked \(link)"
                return
            } catch { continue }
        }
        cliMessage = "No writable bin folder found; copy the path above instead."
    }
}

struct HistorySettings: View {
    @AppStorage("historyRetentionDays", store: KestrelPrefs.shared) private var retention = 30
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Keep history for", selection: $retention) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("6 months").tag(182); Text("1 year").tag(365)
                }
                .onChange(of: retention) { _, v in model.history.prune(retentionDays: v) }
                LabeledContent("Stored in", value: HistoryStore.defaultPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                LabeledContent("Size", value: Fmt.bytes(model.history.fileSize))
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: HistoryStore.defaultPath)]) }
                    Button("Clear history…", role: .destructive) {
                        if Confirm.ask(String(localized: "Clear all history?"), String(localized: "This can't be undone."), action: String(localized: "Clear")) { model.history.prune(retentionDays: 0) }
                    }
                }
            } footer: { Text("One reading per minute for each metric and the busiest apps, kept in a single local file.") }
            SwiftUI.Section("Fan helper") {
                FanHelperRow()
            }
        }
        .formStyle(.grouped)
    }
}

struct FanHelperRow: View {
    @ObservedObject var fans = FanControl.shared
    var body: some View {
        HStack {
            Text(fans.helperInstalled ? "Installed" : "Not installed").foregroundStyle(.secondary)
            Spacer()
            if fans.helperInstalled { Button("Uninstall") { fans.uninstallHelper() } } else { Button("Install…") { fans.installHelper() } }
        }
        if let e = fans.lastError { Text(e).font(.caption).foregroundStyle(Theme.strain) }
    }
}
