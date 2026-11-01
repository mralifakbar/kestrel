import SwiftUI
import KestrelCore

// MARK: - Projects (dev servers & ports)

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "Projects", subtitle: "Dev servers and the ports they hold, grouped by project folder")
                let idle = model.holders.filter(\.isIdle)
                if !idle.isEmpty {
                    Button { stopIdle(idle) } label: { Label("Stop \(idle.count) idle", systemImage: "moon.zzz") }
                }
                Button { model.forceRefreshDev() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            if model.projects.isEmpty {
                Panel { Text("No dev servers or listening ports right now.").foregroundStyle(.secondary) }
            }
            ForEach(model.projects) { g in
                Panel(icon: "folder") {
                    HStack {
                        Image(systemName: g.path == "Other" ? "tray" : "folder.fill").foregroundStyle(Theme.color(.cpu))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(g.name).font(.headline)
                            if g.path != "Other" { Text(g.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("\(Fmt.cpu(g.totalCPU, cores: model.cores)) · \(Fmt.bytes(g.totalMemory))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if g.path != "Other" {
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: g.path)) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Open folder")
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(g.servers) { s in ServerRow(server: s); if s.id != g.servers.last?.id { Divider() } }
                    }
                }
            }
        }
    }

    func stopIdle(_ idle: [PortHolder]) {
        let list = idle.map { "• \($0.kind) on :\($0.ports.map(String.init).joined(separator: ", :")) — \($0.projectName ?? $0.name)" }.joined(separator: "\n")
        guard Confirm.ask(String(localized: "Stop \(idle.count) idle dev server(s)?"), list, action: String(localized: "Stop")) else { return }
        idle.forEach { ProcessControl.terminateTree($0.pid) }
        model.forceRefreshDev()
    }
}

struct ServerRow: View {
    @EnvironmentObject var model: AppModel
    var server: PortHolder
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.kind).font(.callout.weight(.semibold))
                    if server.isIdle { Pill(text: "Idle \(Int(server.idleMinutes))m", color: Theme.warn) }
                    if server.established > 0 { Pill(text: "\(server.established) connected", color: Theme.good) }
                }
                Text(server.command.isEmpty ? server.name : server.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(server.ports.prefix(4), id: \.self) { p in
                    Button(":" + String(p)) { NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!) }
                        .buttonStyle(.bordered).controlSize(.small).help("Open http://localhost:\(p)")
                }
            }
            Text(Fmt.cpu(server.cpu, cores: model.cores)).frame(width: 50, alignment: .trailing)
            Text(Fmt.bytes(server.memory)).frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
            Text(verbatim: "\(server.pid)").frame(width: 56, alignment: .trailing).foregroundStyle(.tertiary)
            Menu {
                Button("Inspect") { model.inspectedPID = server.pid; model.selection = .apps }
                if let cwd = server.cwd { Button("Open in Terminal") { NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) } }
                Divider()
                Button("Force stop") { stop(force: true) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 24)
            Button("Stop") { stop(force: false) }.controlSize(.small)
        }
        .font(.callout.monospacedDigit())
        .padding(.vertical, 6)
    }

    func stop(force: Bool) {
        let ports = server.ports.map { ":\($0)" }.joined(separator: ", ")
        guard Confirm.ask(String(localized: "Stop \(server.kind) on \(ports)?"), String(localized: "This quits pid \(server.pid) and anything it started."), action: force ? String(localized: "Force Stop") : String(localized: "Stop")) else { return }
        ProcessControl.terminateTree(server.pid, force: force)
        model.forceRefreshDev()
    }
}

// MARK: - Agents

struct AgentsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("limitsEnabled", store: KestrelPrefs.shared) private var limitsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Agents", subtitle: "Coding agent sessions, what they started, and how much of your plan is left")
            if model.agents.isEmpty {
                Panel { Text("No coding agents running. Kestrel recognises Claude Code, Codex, Gemini CLI, Aider, OpenCode, Cursor Agent, GitHub Copilot CLI, Amp, Kiro and Goose.").foregroundStyle(.secondary) }
            }
            ForEach(model.agents) { a in AgentCard(session: a) }

            HStack(alignment: .top, spacing: 14) {
                Panel("Usage limits", icon: "gauge.with.needle", accessory: {
                    if limitsEnabled {
                        if model.limitsLoading { ProgressView().controlSize(.small) }
                        Button { model.forceRefreshLimits() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    }
                }) {
                    if !limitsEnabled {
                        Text("Turn on in Settings → Integrations to see remaining quota, reset times and pace for Claude, Codex, Copilot and Cursor. This is the only feature that talks to the network.").font(.callout).foregroundStyle(.secondary)
                        Button("Open Settings") { WindowOpener.openSettings() }
                    } else if model.limits.isEmpty && !model.limitsLoading {
                        Text("No supported providers found on this Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(model.limits) { p in ProviderLimitView(provider: p) }
                }
                Panel("Tokens", icon: "number") {
                    if model.tokens.isEmpty { Text("No local session logs found.").foregroundStyle(.secondary) }
                    ForEach(model.tokens) { t in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t.provider).font(.headline)
                            FigureGrid(items: [("Today", Fmt.tokens(t.today), Theme.color(.cpu)), ("Output today", Fmt.tokens(t.outputToday), nil),
                                               ("Last 7 days", Fmt.tokens(t.week), Theme.color(.memory)), ("Sessions today", "\(t.sessionsToday)", nil)], columns: 2)
                        }
                        .padding(.bottom, 4)
                    }
                    Text("Counted from local logs, including cached input.").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 300)
            }
        }
    }
}

struct AgentCard: View {
    @EnvironmentObject var model: AppModel
    var session: AgentSession
    @State private var expanded = true

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.color(.neural)).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.agent).font(.headline)
                        Pill(text: LocalizedStringKey(session.status), color: session.status == "Working" ? Theme.good : Theme.warn)
                        if let t = session.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("\(session.project ?? "—") · \(session.cwd?.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "") · up \(Fmt.duration(-(session.started ?? Date()).timeIntervalSinceNow))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Fmt.cpu(session.cpu, cores: model.cores)).font(.callout.monospacedDigit())
                    Text(Fmt.bytes(session.memory)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Quit session") {
                    let n = session.children.count
                    guard Confirm.ask(String(localized: "Quit \(session.agent) in \(session.project ?? "this folder")?"),
                                      String(localized: "This also quits the \(n) process(es) it started.") + (session.ports.isEmpty ? "" : "\n" + String(localized: "Frees ports \(session.ports.map(String.init).joined(separator: ", ")).")),
                                      action: String(localized: "Quit")) else { return }
                    ProcessControl.terminateTree(session.pid)
                    model.forceRefreshDev()
                }
            }
            if !session.children.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(spacing: 3) {
                        ForEach(session.children) { c in
                            HStack {
                                Text(verbatim: "\(c.pid)").foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                                Text(c.command.isEmpty ? c.name : c.command).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                ForEach(c.ports, id: \.self) { p in Button(":" + String(p)) { NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!) }.buttonStyle(.bordered).controlSize(.mini) }
                                Text(Fmt.cpu(c.cpu, cores: model.cores)).frame(width: 46, alignment: .trailing)
                                Text(Fmt.bytes(c.memory)).frame(width: 64, alignment: .trailing).foregroundStyle(.secondary)
                                Button { Confirm.quit(pids: [c.pid], name: c.name, force: false, tree: true) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                            }
                            .font(.caption.monospaced())
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Started \(session.children.count) process(es)\(session.ports.isEmpty ? "" : " · ports " + session.ports.map(String.init).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var icon: String {
        switch session.agent {
        case "Claude Code": "asterisk"
        case "Codex": "chevron.left.forwardslash.chevron.right"
        case "Gemini CLI": "sparkle"
        case "GitHub Copilot": "airplane"
        case "Goose": "bird"
        default: "terminal"
        }
    }
}

struct ProviderLimitView: View {
    var provider: ProviderLimits
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.name).font(.headline)
                if let p = provider.plan { Pill(text: LocalizedStringKey(p), color: Theme.color(.memory)) }
                Spacer()
                Text("updated \(provider.updated.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
            if let e = provider.error { Text(e).font(.caption).foregroundStyle(.secondary) }
            ForEach(provider.windows) { w in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(w.label).font(.callout)
                        Spacer()
                        Text("\(Fmt.percent(w.remaining)) left").font(.callout.monospacedDigit().weight(.semibold))
                    }
                    Meter(value: w.used, color: Theme.level(w.used, base: Theme.color(.cpu)), height: 7)
                    HStack {
                        if let r = w.resetsAt { Text("Resets in \(Fmt.duration(r.timeIntervalSinceNow))") }
                        if let d = w.detail { Text("· \(d)") }
                        Spacer()
                        if let p = w.pace {
                            Text(w.paceText).foregroundStyle(p > 1.15 ? Theme.strain : p < 0.85 ? Theme.good : .secondary)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Containers

struct ContainersView: View {
    @EnvironmentObject var model: AppModel
    var groups: [(String, [ContainerInfo])] {
        Dictionary(grouping: model.containers, by: { $0.composeProject ?? "" }).sorted { ($0.key.isEmpty ? "~" : $0.key) < ($1.key.isEmpty ? "~" : $1.key) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "Containers", subtitle: model.dockerAvailable ? "\(model.containers.filter { $0.state == "running" }.count) running · \(model.containers.count) total" : "Docker isn't installed or isn't running")
                Button { model.forceRefreshDocker() } label: { Image(systemName: "arrow.clockwise") }
            }
            if !model.dockerAvailable {
                Panel { Text("Install Docker Desktop, OrbStack or Colima and Kestrel will show per-container CPU, memory, network and ports, grouped by Compose project.").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.0) { name, items in
                Panel(icon: "shippingbox") {
                    HStack {
                        Image(systemName: name.isEmpty ? "cube" : "square.stack.3d.up").foregroundStyle(Theme.color(.cpu))
                        Text(name.isEmpty ? "Standalone containers" : name).font(.headline)
                        Spacer()
                        if !name.isEmpty {
                            Button("Stop all") { act("stop", items.map(\.id), name) }.controlSize(.small)
                            Button("Restart all") { act("restart", items.map(\.id), name) }.controlSize(.small)
                        }
                    }
                    ForEach(items) { c in ContainerRow(c: c) }
                }
            }
        }
    }

    func act(_ verb: String, _ ids: [String], _ name: String) {
        guard Confirm.ask(String(localized: "\(verb.capitalized) \(ids.count) container(s) in \(name)?"), action: verb.capitalized) else { return }
        DispatchQueue.global().async { Docker.action(verb, ids); DispatchQueue.main.async { model.forceRefreshDocker() } }
    }
}

struct ContainerRow: View {
    @EnvironmentObject var model: AppModel
    var c: ContainerInfo
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(c.state == "running" ? Theme.good : c.state == "paused" ? Theme.warn : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.composeService ?? c.name).font(.callout.weight(.medium))
                Text("\(c.image) · \(c.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if c.state == "running" {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f%% CPU", c.cpuPercent)).monospacedDigit()
                    Text(c.memUsage).font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 140, alignment: .trailing)
                Text(c.netIO).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
            }
            Text(c.ports.isEmpty ? "" : c.ports).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).frame(width: 170, alignment: .trailing)
            Menu {
                if c.state == "running" {
                    Button("Stop") { run("stop") }
                    Button("Restart") { run("restart") }
                    Button("Pause") { run("pause") }
                } else if c.state == "paused" {
                    Button("Resume") { run("unpause") }
                } else {
                    Button("Start") { run("start") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }

    func run(_ verb: String) {
        if verb == "stop" || verb == "restart" {
            guard Confirm.ask(String(localized: "\(verb.capitalized) \(c.name)?"), action: verb.capitalized) else { return }
        }
        DispatchQueue.global().async { Docker.action(verb, [c.id]); DispatchQueue.main.async { model.forceRefreshDocker() } }
    }
}
