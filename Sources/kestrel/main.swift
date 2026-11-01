import Foundation
import KestrelCore

// MARK: - Output helpers

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()

func json<T: Encodable>(_ v: T) -> String { String(decoding: (try? encoder.encode(v)) ?? Data(), as: UTF8.self) }

func table(_ header: [String], _ rows: [[String]]) -> String {
    var widths = header.map(\.count)
    for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
    func line(_ r: [String]) -> String {
        r.enumerated().map { i, c in
            let w = widths[min(i, widths.count - 1)]
            return i == r.count - 1 ? c : c.padding(toLength: w, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }
    return ([line(header), line(widths.map { String(repeating: "─", count: $0) })] + rows.map(line)).joined(separator: "\n")
}

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

// MARK: - Commands (shared by CLI and MCP)

enum Commands {
    static let monitor = SystemMonitor()

    static func statusText(_ s: SystemSnapshot) -> String {
        var lines = [
            "\(s.hostName) — \(s.model), \(s.chip) — up \(Fmt.duration(s.uptime))",
            "CPU      \(Fmt.percent(s.cpu.total)) (user \(Fmt.percent(s.cpu.user)), system \(Fmt.percent(s.cpu.system)))  load \(String(format: "%.2f %.2f %.2f", s.cpu.load1, s.cpu.load5, s.cpu.load15))",
            "Memory   \(Fmt.bytes(s.memory.used)) of \(Fmt.bytes(s.memory.total))  pressure \(s.memory.pressureName)  swap \(Fmt.bytes(s.memory.swapUsed))",
            "GPU      \(Fmt.percent(s.gpu.utilization))",
            "Disk     read \(Fmt.rate(s.disk.readBps))  write \(Fmt.rate(s.disk.writeBps))",
            "Network  down \(Fmt.rate(s.network.inBps))  up \(Fmt.rate(s.network.outBps))",
        ]
        if s.power.available {
            lines.append("Power    CPU \(Fmt.watts(s.power.cpuWatts))  GPU \(Fmt.watts(s.power.gpuWatts))  ANE \(Fmt.watts(s.power.aneWatts))" + (s.power.systemWatts > 0 ? "  system \(Fmt.watts(s.power.systemWatts))" : ""))
        }
        if s.thermals.cpuC > 0 { lines.append("Thermal  CPU \(Fmt.temp(s.thermals.cpuC))  GPU \(Fmt.temp(s.thermals.gpuC))  \(s.thermals.fans.map { "fan \(Int($0.rpm)) rpm" }.joined(separator: " "))  state \(s.thermals.thermalState)") }
        if s.battery.present { lines.append("Battery  \(Fmt.percent(s.battery.percent))\(s.battery.isCharging ? " charging" : "")  health \(Fmt.percent(s.battery.health))  cycles \(s.battery.cycleCount)") }
        for v in s.disk.volumes { lines.append("Volume   \(v.name): \(Fmt.bytes(v.free)) free of \(Fmt.bytes(v.total))") }
        return lines.joined(separator: "\n")
    }

    struct StatusJSON: Encodable {
        var host: String, model: String, chip: String, uptimeSeconds: Double
        var cpu: CPUStats, memory: MemoryStats, gpu: GPUStats, power: PowerStats, disk: DiskStats, network: NetworkStats, battery: BatteryStats, thermals: ThermalStats
    }

    static func status(jsonOut: Bool) -> String {
        let s = monitor.warmSample(includeProcesses: false)
        if jsonOut { return json(StatusJSON(host: s.hostName, model: s.model, chip: s.chip, uptimeSeconds: s.uptime, cpu: s.cpu, memory: s.memory, gpu: s.gpu, power: s.power, disk: s.disk, network: s.network, battery: s.battery, thermals: s.thermals)) }
        return statusText(s)
    }

    static func top(limit: Int, sort: String, jsonOut: Bool, processes: Bool = false) -> String {
        let s = monitor.warmSample()
        if processes {
            var p = s.processes
            p.sort { sort == "mem" ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            p = Array(p.prefix(limit))
            if jsonOut { return json(p) }
            return table(["PID", "PROCESS", "CPU", "MEMORY", "THREADS"], p.map { ["\($0.pid)", clip($0.name, 36), Fmt.cpu($0.cpu, cores: s.cpu.coreCount), Fmt.bytes($0.memory), "\($0.threads)"] })
        }
        var apps = s.apps
        apps.sort { sort == "mem" ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        apps = Array(apps.prefix(limit))
        if jsonOut { return json(apps) }
        return table(["APP", "CPU", "MEMORY", "PROCS", "DISK R/W", "MAIN PID"],
                     apps.map { [clip($0.name, 34), Fmt.cpu($0.cpu, cores: s.cpu.coreCount), Fmt.bytes($0.memory), "\($0.processCount)",
                                 "\(Fmt.compactRate($0.diskReadBps))/\(Fmt.compactRate($0.diskWriteBps))", "\($0.mainPID)"] })
            + "\n\n\(s.apps.count) apps from \(s.processes.count) processes"
    }

    static func ports(jsonOut: Bool) -> String {
        let s = monitor.warmSample()
        let holders = DevServerTracker().scan(processes: s.processes)
        if jsonOut { return json(DevServerTracker.group(holders)) }
        if holders.isEmpty { return "No dev servers or listening ports found." }
        var out: [String] = []
        for g in DevServerTracker.group(holders) {
            out.append("▸ \(g.name)\(g.path == "Other" ? "" : "  (\(g.path))")")
            out.append(table(["PID", "KIND", "PORTS", "CPU", "MEMORY", "CONNS", "STATE"],
                             g.servers.map { ["\($0.pid)", $0.kind, $0.ports.map(String.init).joined(separator: ","), Fmt.cpu($0.cpu, cores: s.cpu.coreCount), Fmt.bytes($0.memory), "\($0.established)", $0.isIdle ? "idle" : "active"] }))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func agents(jsonOut: Bool) -> String {
        let s = monitor.warmSample()
        let sessions = AgentTracker().scan(processes: s.processes)
        if jsonOut { return json(sessions) }
        if sessions.isEmpty { return "No coding agents running." }
        return sessions.map { a in
            var l = "● \(a.agent) [\(a.status)] pid \(a.pid) — \(a.project ?? "?")  \(Fmt.cpu(a.cpu, cores: s.cpu.coreCount)) CPU, \(Fmt.bytes(a.memory))"
            if let t = a.title { l += "  “\(t)”" }
            for c in a.children.prefix(12) { l += "\n    └ \(c.pid) \(clip(c.command.isEmpty ? c.name : c.command, 80))\(c.ports.isEmpty ? "" : "  ports " + c.ports.map(String.init).joined(separator: ","))" }
            if a.children.count > 12 { l += "\n    └ … \(a.children.count - 12) more" }
            return l
        }.joined(separator: "\n")
    }

    static func limits(jsonOut: Bool) -> String {
        let l = UsageLimits.fetchAll()
        let tokens = TokenCounter().usage()
        if jsonOut {
            struct Out: Encodable { var limits: [ProviderLimits]; var tokens: [TokenUsage] }
            return json(Out(limits: l, tokens: tokens))
        }
        var out: [String] = []
        for p in l {
            out.append("\(p.name)\(p.plan.map { " (\($0))" } ?? "")")
            if let e = p.error { out.append("   \(e)") }
            for w in p.windows {
                let bar = String(repeating: "█", count: Int(w.used * 20)) + String(repeating: "░", count: 20 - min(20, Int(w.used * 20)))
                var line = "   \(w.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(bar) \(Fmt.percent(w.used)) used"
                if let r = w.resetsAt { line += "  resets in \(Fmt.duration(r.timeIntervalSinceNow))" }
                if !w.paceText.isEmpty { line += "  · \(w.paceText)" }
                if let d = w.detail { line += "  (\(d))" }
                out.append(line)
            }
        }
        if l.isEmpty { out.append("No providers found. (Claude Code, Codex, Copilot via gh, Cursor)") }
        if !tokens.isEmpty {
            out.append("")
            out.append(table(["TOKENS", "TODAY", "OUTPUT TODAY", "LAST 7 DAYS"], tokens.map { [$0.provider, Fmt.tokens($0.today), Fmt.tokens($0.outputToday), Fmt.tokens($0.week)] }))
        }
        return out.joined(separator: "\n")
    }

    static func resolvePID(_ q: String) -> Int32? {
        if let p = Int32(q) { return p }
        let lower = q.lowercased()
        return ProcInfo.allPIDs().first { ProcessNames.name($0).lowercased() == lower } ?? ProcInfo.allPIDs().first { ProcessNames.name($0).lowercased().contains(lower) }
    }

    static func process(_ q: String, format: String) -> String {
        guard let pid = resolvePID(q), let d = ProcessInspector.detail(pid: pid) else { return "No process matching “\(q)”." }
        switch format {
        case "json": return json(d)
        case "csv": return d.asCSV
        default: return d.asText
        }
    }

    static func containers(jsonOut: Bool) -> String {
        let r = Docker.containers()
        if !r.available { return "Docker isn't installed or isn't running." }
        if jsonOut { return json(r.items) }
        if r.items.isEmpty { return "No containers." }
        return table(["PROJECT", "NAME", "STATE", "CPU", "MEMORY", "NET I/O", "PORTS"],
                     r.items.map { [$0.composeProject ?? "—", $0.name, $0.state, String(format: "%.1f%%", $0.cpuPercent), $0.memUsage, $0.netIO, clip($0.ports, 40)] })
    }

    static func history(_ key: String, range: String, jsonOut: Bool) -> String {
        let secs: Double = ["1h": 3600, "6h": 21600, "24h": 86400, "7d": 604800, "30d": 2592000, "90d": 7776000, "1y": 31536000][range] ?? 3600
        let store = HistoryStore(readOnly: true)
        guard store.isOpen else { return "No history yet — open the Kestrel app to start recording." }
        let pts = store.series(key, since: Date().addingTimeInterval(-secs), points: 40)
        if jsonOut { return json(pts.map { ["t": $0.date.timeIntervalSince1970, "v": $0.value] }) }
        guard let mx = pts.map(\.value).max(), mx > 0 else { return "No data for “\(key)” in \(range)." }
        let df = DateFormatter(); df.dateFormat = secs > 86400 ? "MMM d HH:mm" : "HH:mm"
        return pts.map { p in "\(df.string(from: p.date))  \(String(repeating: "▇", count: max(1, Int(p.value / mx * 40))))  \(String(format: "%.3g", p.value))" }.joined(separator: "\n")
    }

    static func stop(pid: Int32, confirm: (String) -> Bool, source: String) -> String {
        let name = ProcessNames.name(pid)
        guard confirm("Quit \(name) (pid \(pid)) and everything it started?") else { return "Cancelled." }
        let n = ProcessControl.terminateTree(pid)
        return "Sent quit to \(n) process(es) for \(name)."
    }

    static func idleServers() -> [PortHolder] {
        let tracker = DevServerTracker()
        // Idle detection needs history; fall back to "no connections and ~0 CPU" for one-shot use.
        let s = monitor.warmSample(interval: 2)
        return tracker.scan(processes: s.processes).filter { $0.established == 0 && $0.cpu < 0.5 }
    }
}

// MARK: - MCP server (stdio, JSON-RPC 2.0)

enum MCP {
    static let tools: [[String: Any]] = [
        tool("get_status", "Current Mac readings: CPU, memory, GPU, power, disk, network, battery, temperatures.", [:]),
        tool("get_top_apps", "Apps using the most resources (helpers folded into their app).", ["limit": ["type": "integer"], "sort": ["type": "string", "enum": ["cpu", "mem"]]]),
        tool("get_ports", "Dev servers and listening ports grouped by project folder, with idle flags.", [:]),
        tool("get_agents", "Running coding-agent sessions (Claude Code, Codex, Gemini CLI, …), whether they're working or waiting, and what they started.", [:]),
        tool("get_limits", "AI subscription usage limits and token counts.", [:]),
        tool("inspect_process", "Detailed info on one process: signature, parent, command line, memory, open files, ports, children.", ["process": ["type": "string", "description": "PID or name"]], required: ["process"]),
        tool("get_history", "Historical values of a metric (cpu, mem_used, gpu, net_in, net_out, disk_read, disk_write, temp_cpu, cpu_w, gpu_w, battery…).", ["metric": ["type": "string"], "range": ["type": "string", "enum": ["1h", "6h", "24h", "7d", "30d", "90d", "1y"]]], required: ["metric"]),
        tool("get_containers", "Docker containers with CPU, memory, network and ports.", [:]),
        tool("request_stop", "Ask the user to quit a process and everything it started. The user must approve in the Kestrel app; nothing is quit otherwise.", ["pid": ["type": "integer"], "reason": ["type": "string"]], required: ["pid"]),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        switch name {
        case "get_status": return (Commands.status(jsonOut: true), false)
        case "get_top_apps": return (Commands.top(limit: a["limit"] as? Int ?? 15, sort: a["sort"] as? String ?? "cpu", jsonOut: true), false)
        case "get_ports": return (Commands.ports(jsonOut: true), false)
        case "get_agents": return (Commands.agents(jsonOut: true), false)
        case "get_limits": return (Commands.limits(jsonOut: true), false)
        case "inspect_process": return (Commands.process("\(a["process"] ?? "")", format: "json"), false)
        case "get_history": return (Commands.history(a["metric"] as? String ?? "cpu", range: a["range"] as? String ?? "1h", jsonOut: true), false)
        case "get_containers": return (Commands.containers(jsonOut: true), false)
        case "request_stop":
            guard let pid = (a["pid"] as? NSNumber)?.int32Value else { return ("Missing pid", true) }
            guard StopBroker.appIsRunning else { return ("Kestrel app isn't running, so the user can't approve. Nothing was quit.", true) }
            let name = ProcessNames.name(pid)
            let ok = StopBroker.requestApproval(pids: [pid], description: "Quit \(name) (pid \(pid)) and everything it started?\n\nReason: \(a["reason"] as? String ?? "—")", source: "MCP client")
            return ok ? ("User approved. Quit \(ProcessControl.terminateTree(pid)) process(es).", false) : ("User declined. Nothing was quit.", false)
        default: return ("Unknown tool \(name)", true)
        }
    }

    static func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }

    static func serve() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let id else { continue } // notification
            var result: [String: Any]?
            var error: [String: Any]?
            switch method {
            case "initialize":
                result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "kestrel", "version": "1.0.0"],
                          "instructions": "Read-only view of this Mac's health. Quitting anything requires the user's approval in the Kestrel app."]
            case "ping": result = [:]
            case "tools/list": result = ["tools": tools]
            case "tools/call":
                if !KestrelPrefs.mcpEnabled {
                    result = ["content": [["type": "text", "text": "The Kestrel MCP server is turned off. Enable it in Kestrel → Settings → Integrations."]], "isError": true]
                } else {
                    let (text, isErr) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
                    result = ["content": [["type": "text", "text": text]], "isError": isErr]
                }
            default: error = ["code": -32601, "message": "Method not found"]
            }
            var resp: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let result { resp["result"] = result } else { resp["error"] = error }
            send(resp)
        }
        exit(0)
    }
}

// MARK: - Entry

let usage = """
kestrel — your Mac's health from the terminal

USAGE
  kestrel status [--json]                 System overview
  kestrel top [-n N] [--mem] [--procs] [--json]
                                          Apps (or raw processes) using the most
  kestrel ports [--json]                  Dev servers & listening ports by project
  kestrel agents [--json]                 Coding agents and what they started
  kestrel limits [--json]                 AI usage limits + tokens used
  kestrel process <pid|name> [--json|--csv]
                                          Inspect one process
  kestrel containers [--json]             Docker containers
  kestrel history <metric> [--range 1h|6h|24h|7d|30d|90d|1y] [--json]
  kestrel stop <pid> [--yes]              Quit a process and everything it started
  kestrel stop --idle [--yes]             Quit idle dev servers
  kestrel sensors                         Raw temperature sensors and fans
  kestrel mcp                             Run the MCP server on stdio
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }
func option(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func ask(_ q: String) -> Bool {
    print("\(q) [y/N] ", terminator: "")
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

let jsonOut = flag("--json")
let cmd = args.first ?? "status"
if !args.isEmpty { args.removeFirst() }

switch cmd {
case "status": print(Commands.status(jsonOut: jsonOut))
case "top":
    let n = Int(option("-n") ?? "15") ?? 15
    print(Commands.top(limit: n, sort: flag("--mem") ? "mem" : "cpu", jsonOut: jsonOut, processes: flag("--procs")))
case "ports": print(Commands.ports(jsonOut: jsonOut))
case "agents": print(Commands.agents(jsonOut: jsonOut))
case "limits": print(Commands.limits(jsonOut: jsonOut))
case "process":
    let fmt = flag("--csv") ? "csv" : jsonOut ? "json" : "text"
    guard let q = args.first else { print("usage: kestrel process <pid|name>"); exit(1) }
    print(Commands.process(q, format: fmt))
case "containers": print(Commands.containers(jsonOut: jsonOut))
case "history":
    let range = option("--range") ?? "1h"
    print(Commands.history(args.first ?? "cpu", range: range, jsonOut: jsonOut))
case "stop":
    let yes = flag("--yes") || flag("-y")
    if flag("--idle") {
        let idle = Commands.idleServers()
        if idle.isEmpty { print("No idle dev servers."); exit(0) }
        for s in idle { print("  \(s.pid)  \(s.kind)  ports \(s.ports.map(String.init).joined(separator: ","))  \(s.projectName ?? "")") }
        guard yes || ask("Quit these \(idle.count) server(s)?") else { print("Cancelled."); exit(0) }
        for s in idle { ProcessControl.terminateTree(s.pid) }
        print("Stopped \(idle.count) server(s).")
    } else {
        guard let q = args.first, let pid = Commands.resolvePID(q) else { print("usage: kestrel stop <pid|name> | --idle"); exit(1) }
        print(Commands.stop(pid: pid, confirm: { yes || ask($0) }, source: "CLI"))
    }
case "sensors":
    let t = SMC.thermals()
    print(table(["KEY", "GROUP", "TEMP"], t.sensors.map { [$0.key, $0.group, Fmt.temp($0.celsius)] }))
    for f in t.fans { print("Fan \(f.index): \(Int(f.rpm)) rpm (min \(Int(f.minRPM)), max \(Int(f.maxRPM)), target \(Int(f.targetRPM)))\(f.isManual ? " manual" : "")") }
case "debug-ioreport": PowerSampler.channelNames().forEach { print($0) }
case "mcp": MCP.serve()
case "--version", "version":
    print("kestrel \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? KestrelVersion.string)")
case "help", "-h", "--help": print(usage)
default: print(usage); exit(1)
}
