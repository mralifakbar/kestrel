import SwiftUI
import KestrelCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, menuBar, layout, alerts, integrations, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .menuBar: String(localized: "Menu Bar")
        case .layout: String(localized: "Layout")
        case .alerts: String(localized: "Alerts")
        case .integrations: String(localized: "Integrations")
        case .history: String(localized: "History")
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Dock, login, units, colors")
        case .menuBar: String(localized: "Readings in the menu bar")
        case .layout: String(localized: "Sections and the dropdown")
        case .alerts: String(localized: "When to send a notification")
        case .integrations: String(localized: "AI limits, MCP, command line")
        case .history: String(localized: "Retention, fan helper")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .layout: "sidebar.left"
        case .alerts: "bell"
        case .integrations: "puzzlepiece.extension"
        case .history: "clock"
        }
    }

    /// Words a search can find this page by.
    var keywords: String {
        switch self {
        case .general: "dock login startup refresh interval units celsius fahrenheit temperature bytes bits cpu percent appearance colors palette compact language"
        case .menuBar: "menu bar items status graph value cpu memory gpu network disk temperature power battery"
        case .layout: "sections order hide dropdown reorder reset"
        case .alerts: "notifications alerts cpu memory disk network pressure temperature"
        case .integrations: "ai usage limits claude codex copilot cursor mcp cli command line dev servers idle"
        case .history: "history retention keep size clear finder fan helper"
        }
    }
}

struct SettingsView: View {
    @State private var page: SettingsPage = .general
    @State private var search = ""

    private var pages: [SettingsPage] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { ($0.title + " " + $0.subtitle + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(pages, selection: Binding(get: { page }, set: { if let p = $0 { page = p } })) { p in
                VStack(alignment: .leading, spacing: 1) {
                    Label(p.title, systemImage: p.symbol)
                    Text(p.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 26)
                }
                .tag(p)
                .padding(.vertical, 2)
            }
            .searchable(text: $search, placement: .sidebar, prompt: Text("Search settings"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            SettingsPageContent(page: page)
        }
    }
}

/// One settings page, scrollable.
struct SettingsPageContent: View {
    var page: SettingsPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title).font(.largeTitle.bold()).padding(.bottom, 16)
                detail
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(page)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general: GeneralSettings()
        case .menuBar: MenuBarSettings()
        case .layout: LayoutSettings()
        case .alerts: AlertSettings()
        case .integrations: IntegrationSettings()
        case .history: HistorySettings()
        }
    }
}

/// The trailing switch every on/off setting uses.
private struct Switch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden() }
}

/// A grey footnote at the end of a card.
private struct Footnote: View {
    var text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
        Section2("App") {
            SettingRow("Show in Dock") { Switch(isOn: $showInDock) }
                .onChange(of: showInDock) { _, v in NSApp.setActivationPolicy(v ? .regular : .accessory); if v { WindowOpener.openMain() } }
            SettingRow("Open at login") { Switch(isOn: $login) }
                .onChange(of: login) { _, v in LoginItem.set(v) }
            SettingRow("Refresh while window is open", detail: "With the window closed Kestrel samples every 5 seconds.") {
                Picker("", selection: $fastInterval) {
                    Text("Every second").tag(1.0); Text("Every 2 seconds").tag(2.0); Text("Every 3 seconds").tag(3.0)
                }
                .labelsHidden().fixedSize()
            }
            .onChange(of: fastInterval) { _, _ in AppModel.shared.reschedule() }
        }
        Section2("Units") {
            SettingRow("Temperature") {
                Picker("", selection: $tempUnit) { Text("Celsius").tag("celsius"); Text("Fahrenheit").tag("fahrenheit") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow("Transfer rates") {
                Picker("", selection: $rateUnit) { Text("Bytes (MB/s)").tag("bytes"); Text("Bits (Mbps)").tag("bits") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow("CPU percentages") {
                Picker("", selection: $cpuScale) { Text("Per core (100% = one core)").tag("perCore"); Text("Per Mac (100% = all cores)").tag("perMac") }
                    .labelsHidden().fixedSize()
            }
        }
        Section2("Appearance") {
            SettingRow("Colors") {
                Picker("", selection: $palette) { ForEach(Palette.allCases) { Text($0.label).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow("Compact layout") { Switch(isOn: $compact) }
            Footnote("Language follows your Mac (System Settings → General → Language & Region).")
        }
    }
}

struct MenuBarSettings: View {
    @State private var enabled = BarPrefs.enabled
    @State private var styles: [BarMetric: BarStyle] = Dictionary(uniqueKeysWithValues: BarMetric.allCases.map { ($0, BarPrefs.style($0)) })

    var body: some View {
        Section2("Items") {
            ForEach(BarMetric.allCases) { m in
                HStack(spacing: 10) {
                    Image(systemName: m.icon).foregroundStyle(Color.accentColor).frame(width: 20)
                    Text(m.title)
                    Spacer(minLength: 16)
                    Picker("", selection: Binding(get: { styles[m] ?? .value }, set: { styles[m] = $0; UserDefaults.standard.set($0.rawValue, forKey: "menubar.style.\(m.rawValue)") })) {
                        ForEach(BarStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 150).disabled(!enabled.contains(m))
                    Switch(isOn: Binding(get: { enabled.contains(m) }, set: { on in
                        if on { enabled.append(m) } else { enabled.removeAll { $0 == m } }
                        BarPrefs.enabled = enabled
                    }))
                }
            }
            Footnote("Each reading is its own menu bar item and turns red when under strain. Hold ⌘ and drag items in the menu bar to reorder them.")
        }
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
        Section2("Window sections") {
            Footnote("Drag to reorder, untick to hide.")
            List {
                ForEach(sections) { s in
                    Toggle(isOn: Binding(get: { !hidden(hiddenSections).contains(s.rawValue) }, set: { hiddenSections = toggle(hiddenSections, s.rawValue, show: $0) })) {
                        Label(s.title, systemImage: s.icon)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in var a = sections; a.move(fromOffsets: from, toOffset: to); sectionOrder = a.map(\.rawValue).joined(separator: ",") }
            }
            .modifier(CardList(rows: sections.count))
        }
        Section2("Menu bar dropdown") {
            Footnote("Drag to reorder, untick to hide.")
            List {
                ForEach(blocks) { b in
                    Toggle(b.label, isOn: Binding(get: { !hidden(dropdownHidden).contains(b.rawValue) }, set: { dropdownHidden = toggle(dropdownHidden, b.rawValue, show: $0) }))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { from, to in var a = blocks; a.move(fromOffsets: from, toOffset: to); dropdownOrder = a.map(\.rawValue).joined(separator: ",") }
            }
            .modifier(CardList(rows: blocks.count))
        }
        Button("Reset layout") { sectionOrder = ""; hiddenSections = ""; dropdownOrder = ""; dropdownHidden = "" }
    }

    func hidden(_ s: String) -> Set<String> { Set(s.split(separator: ",").map(String.init)) }
    func toggle(_ s: String, _ key: String, show: Bool) -> String {
        var h = hidden(s)
        if show { h.remove(key) } else { h.insert(key) }
        return h.sorted().joined(separator: ",")
    }
}

/// A reorderable list laid flat on a settings card: no own background or scrolling.
private struct CardList: ViewModifier {
    var rows: Int
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(rows) * 28 + 4)
            .padding(.horizontal, -8)
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
        Section2 {
            SettingRow("Send notifications") { Switch(isOn: $enabled) }
        }
        Section2("Apps") {
            SettingRow("High CPU") { Switch(isOn: $cpu) }
            if cpu {
                SettingRow("Above \(Int(cpuPercent))% (of one core)") { Stepper("", value: $cpuPercent, in: 50...800, step: 25).labelsHidden() }.padding(.leading, 16)
                SettingRow("For \(Int(cpuSeconds)) seconds") { Stepper("", value: $cpuSeconds, in: 10...600, step: 10).labelsHidden() }.padding(.leading, 16)
            }
            SettingRow("Memory keeps growing") { Switch(isOn: $memory) }
            if memory {
                SettingRow(verbatim: String(format: "Grows by %.1f GB within 10 minutes", memoryGrowth)) { Stepper("", value: $memoryGrowth, in: 0.5...16, step: 0.5).labelsHidden() }.padding(.leading, 16)
            }
            SettingRow("Heavy disk use") { Switch(isOn: $disk) }
            if disk {
                SettingRow("Above \(Int(diskMB)) MB/s") { Stepper("", value: $diskMB, in: 10...2000, step: 10).labelsHidden() }.padding(.leading, 16)
                SettingRow("For \(Int(diskSeconds)) seconds") { Stepper("", value: $diskSeconds, in: 10...600, step: 10).labelsHidden() }.padding(.leading, 16)
            }
            SettingRow("Heavy network use") { Switch(isOn: $network) }
            if network {
                SettingRow("Above \(Int(netMB)) MB/s") { Stepper("", value: $netMB, in: 1...1000, step: 1).labelsHidden() }.padding(.leading, 16)
                SettingRow("For \(Int(netSeconds)) seconds") { Stepper("", value: $netSeconds, in: 10...600, step: 10).labelsHidden() }.padding(.leading, 16)
            }
        }
        Section2("System") {
            SettingRow("Memory pressure turns critical") { Switch(isOn: $pressure) }
            SettingRow("CPU temperature") { Switch(isOn: $temperature) }
            if temperature {
                SettingRow("Above \(Fmt.temp(temperatureC))") { Stepper("", value: $temperatureC, in: 70...110, step: 1).labelsHidden() }.padding(.leading, 16)
            }
        }
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
        Section2("Usage limits") {
            SettingRow("Show AI usage limits") { Switch(isOn: $limitsEnabled) }
                .onChange(of: limitsEnabled) { _, v in if v { AppModel.shared.forceRefreshLimits() } }
            if limitsEnabled {
                ForEach([("claude", "Claude (via Claude Code login)"), ("codex", "Codex (from local session logs)"), ("copilot", "GitHub Copilot (via gh CLI)"), ("cursor", "Cursor")], id: \.0) { id, label in
                    SettingRow(verbatim: label) {
                        Switch(isOn: Binding(get: { providers.contains(id) }, set: { on in
                            if on { providers.insert(id) } else { providers.remove(id) }
                            KestrelPrefs.enabledLimitProviders = providers
                        }))
                    }
                    .padding(.leading, 16)
                }
            }
            Footnote("Reads the sign-in your tools already store on this Mac and asks the provider for your remaining quota every 5 minutes. Off by default; nothing else leaves your Mac.")
        }
        Section2("MCP server") {
            SettingRow("Enable MCP server") { Switch(isOn: $mcpEnabled) }
            if mcpEnabled {
                command("claude mcp add kestrel -- '\(cliPath)' mcp")
                command("codex mcp add kestrel -- '\(cliPath)' mcp")
                Text("Cursor: add {\"kestrel\": {\"command\": \"\(cliPath)\", \"args\": [\"mcp\"]}} to ~/.cursor/mcp.json").font(.caption).textSelection(.enabled)
            }
            Footnote("Lets Claude, Codex and Cursor read your Mac's health. Any request to quit something shows a confirmation here first.")
        }
        Section2("Command line") {
            command("'\(cliPath)' status")
            HStack {
                Button("Install `kestrel` command") { installCLI() }
                if let m = cliMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
        }
        Section2("Dev servers") {
            SettingRow("Flag as idle after \(idleMinutes) minutes without activity") { Stepper("", value: $idleMinutes, in: 5...240, step: 5).labelsHidden() }
        }
    }

    func command(_ c: String) -> some View {
        HStack {
            Text(c).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
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
        Section2 {
            SettingRow("Keep history for") {
                Picker("", selection: $retention) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("6 months").tag(182); Text("1 year").tag(365)
                }
                .labelsHidden().fixedSize()
            }
            .onChange(of: retention) { _, v in model.history.prune(retentionDays: v) }
            SettingRow("Stored in") {
                Text(HistoryStore.defaultPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            SettingRow("Size") { Text(Fmt.bytes(model.history.fileSize)).monospacedDigit().foregroundStyle(.secondary) }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: HistoryStore.defaultPath)]) }
                Button("Clear history…", role: .destructive) {
                    if Confirm.ask(String(localized: "Clear all history?"), String(localized: "This can't be undone."), action: String(localized: "Clear")) { model.history.prune(retentionDays: 0) }
                }
            }
            Footnote("One reading per minute for each metric and the busiest apps, kept in a single local file.")
        }
        Section2("Fan helper") {
            FanHelperRow()
        }
    }
}

struct FanHelperRow: View {
    @ObservedObject var fans = FanControl.shared
    var body: some View {
        SettingRow(fans.helperInstalled ? "Installed" : "Not installed") {
            if fans.helperInstalled { Button("Uninstall") { fans.uninstallHelper() } } else { Button("Install…") { fans.installHelper() } }
        }
        if let e = fans.lastError { Text(e).font(.caption).foregroundStyle(Theme.strain) }
    }
}
