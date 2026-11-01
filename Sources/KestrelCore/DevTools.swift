import Foundation
import Darwin

// MARK: - Dev servers & ports

public struct PortHolder: Codable, Hashable, Identifiable {
    public var id: String { "\(pid)" }
    public var pid: Int32
    public var name: String
    public var command: String
    public var ports: [Int]
    public var addresses: [String]
    public var cwd: String?
    public var project: String?        // project root folder
    public var projectName: String?
    public var cpu: Double
    public var memory: UInt64
    public var established: Int
    public var idleMinutes: Double
    public var isIdle: Bool
    public var started: Date?
    public var kind: String            // e.g. "Vite", "Next.js", "Python", "Node"
}

public struct ProjectGroup: Codable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var servers: [PortHolder]
    public var totalMemory: UInt64 { servers.reduce(0) { $0 + $1.memory } }
    public var totalCPU: Double { servers.reduce(0) { $0 + $1.cpu } }
}

public final class DevServerTracker {
    private var lastActive: [Int32: Date] = [:]
    private var lastCPU: [Int32: Double] = [:]
    private var lastConnections: [Int32: Int] = [:]
    public init() {}

    static let markers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Gemfile", "composer.json",
                          "mix.exs", "pom.xml", "build.gradle", "Package.swift", "deno.json", "bun.lockb", "Makefile", "docker-compose.yml", "compose.yaml"]

    public static func projectRoot(for dir: String) -> String? {
        let home = NSHomeDirectory()
        var url = URL(fileURLWithPath: dir)
        var best: String?
        while url.path.count > 1 && url.path != home {
            for m in markers where FileManager.default.fileExists(atPath: url.appendingPathComponent(m).path) {
                best = url.path
                if m == ".git" { return best }
            }
            url.deleteLastPathComponent()
        }
        return best
    }

    static func kind(name: String, args: [String]) -> String {
        let joined = args.joined(separator: " ").lowercased()
        let pairs: [(String, String)] = [("next", "Next.js"), ("vite", "Vite"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"), ("webpack", "Webpack"),
                                          ("expo", "Expo"), ("storybook", "Storybook"), ("wrangler", "Wrangler"), ("rails", "Rails"), ("manage.py", "Django"),
                                          ("uvicorn", "Uvicorn"), ("flask", "Flask"), ("gunicorn", "Gunicorn"), ("jupyter", "Jupyter"), ("hugo", "Hugo"),
                                          ("php", "PHP"), ("artisan", "Laravel"), ("tsx", "tsx"), ("nodemon", "nodemon"), ("bun", "Bun"), ("deno", "Deno"),
                                          ("cargo", "Cargo"), ("python", "Python"), ("ruby", "Ruby"), ("java", "Java"), ("node", "Node")]
        for (k, v) in pairs where joined.contains(k) || name.lowercased().contains(k) { return v }
        return name
    }

    /// Processes owned by the current user that hold listening TCP ports.
    public func scan(processes: [ProcessUsage]? = nil) -> [PortHolder] {
        let uid = getuid()
        let now = Date()
        let procMap = Dictionary((processes ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PortHolder] = []
        let pids = processes?.filter { $0.uid == uid }.map(\.pid) ?? ProcInfo.allPIDs().filter { ProcInfo.bsdInfo($0)?.pbi_uid == uid }
        for pid in pids {
            let socks = Sockets.sockets(of: pid)
            let listening = socks.filter { $0.proto == "TCP" && $0.state == "LISTEN" }
            guard !listening.isEmpty else { continue }
            let raw = ProcInfo.raw(pid)
            let name = raw?.name ?? ProcessNames.name(pid)
            let path = raw?.path ?? ""
            // Skip regular GUI apps (they hold ports for IPC, not as dev servers) unless they run from a project folder.
            let cwd = ProcInfo.cwd(pid)
            let project = cwd.flatMap { $0 == "/" ? nil : Self.projectRoot(for: $0) }
            if path.contains(".app/") && project == nil { continue }
            let args = ProcInfo.arguments(pid)
            let established = socks.filter { $0.proto == "TCP" && $0.state == "ESTABLISHED" }.count
            let cpuNs = raw?.cpuNs ?? 0
            let cpuDelta = cpuNs - (lastCPU[pid] ?? cpuNs)
            if lastActive[pid] == nil || cpuDelta > 5e7 || established != (lastConnections[pid] ?? established) { lastActive[pid] = now }
            lastCPU[pid] = cpuNs
            lastConnections[pid] = established
            let idleMin = now.timeIntervalSince(lastActive[pid] ?? now) / 60
            let threshold = Double(KestrelPrefs.idleServerMinutes)
            let ports = Array(Set(listening.map(\.localPort))).sorted()
            out.append(PortHolder(pid: pid, name: name, command: args.joined(separator: " "), ports: ports,
                                  addresses: Array(Set(listening.map { "\($0.localAddress):\($0.localPort)" })).sorted(),
                                  cwd: cwd, project: project, projectName: project.map { URL(fileURLWithPath: $0).lastPathComponent },
                                  cpu: procMap[pid]?.cpu ?? 0, memory: procMap[pid]?.memory ?? raw?.footprint ?? 0, established: established,
                                  idleMinutes: idleMin, isIdle: idleMin >= threshold && established == 0, started: raw?.startTime,
                                  kind: Self.kind(name: name, args: args)))
        }
        let alive = Set(out.map(\.pid))
        lastActive = lastActive.filter { alive.contains($0.key) }
        lastCPU = lastCPU.filter { alive.contains($0.key) }
        return out.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    public static func group(_ holders: [PortHolder]) -> [ProjectGroup] {
        var g: [String: [PortHolder]] = [:]
        for h in holders { g[h.project ?? "Other", default: []].append(h) }
        return g.map { ProjectGroup(path: $0.key, name: $0.key == "Other" ? "Other" : URL(fileURLWithPath: $0.key).lastPathComponent, servers: $0.value) }
            .sorted { ($0.path == "Other" ? 1 : 0, $0.name.lowercased()) < ($1.path == "Other" ? 1 : 0, $1.name.lowercased()) }
    }
}

// MARK: - Coding agents

public struct AgentSession: Codable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var agent: String
    public var project: String?
    public var cwd: String?
    public var status: String          // "Working" / "Waiting"
    public var title: String?
    public var started: Date?
    public var cpu: Double
    public var memory: UInt64
    public var children: [Child]
    public var ports: [Int]

    public struct Child: Codable, Hashable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
        public var command: String
        public var ports: [Int]
        public var cpu: Double
        public var memory: UInt64
    }
}

public final class AgentTracker {
    private var cpuHistory: [Int32: [Double]] = [:]
    public init() {}

    static let signatures: [(agent: String, match: (String, [String]) -> Bool)] = [
        ("Claude Code", { n, a in n == "claude" || a.first.map { ($0 as NSString).lastPathComponent == "claude" } == true || a.prefix(2).contains { $0.hasSuffix("/claude-code/cli.js") || $0.hasSuffix("@anthropic-ai/claude-code/cli.js") } }),
        ("Codex", { n, a in n == "codex" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "codex" || $0.contains("@openai/codex") } }),
        ("Gemini CLI", { n, a in n == "gemini" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "gemini" || $0.contains("@google/gemini-cli") } }),
        ("Aider", { n, a in n == "aider" || a.prefix(3).contains { ($0 as NSString).lastPathComponent == "aider" } }),
        ("OpenCode", { n, a in n == "opencode" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "opencode" } }),
        ("Cursor Agent", { n, a in n == "cursor-agent" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "cursor-agent" } }),
        ("GitHub Copilot", { n, a in n == "copilot" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "copilot" || $0.contains("@github/copilot") } }),
        ("Amp", { n, a in n == "amp" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "amp" || $0.contains("@sourcegraph/amp") } }),
        ("Kiro", { n, a in n == "kiro-cli" || n == "kiro" || a.prefix(2).contains { ($0 as NSString).lastPathComponent.hasPrefix("kiro") } }),
        ("Goose", { n, a in n == "goose" || a.prefix(2).contains { ($0 as NSString).lastPathComponent == "goose" } }),
    ]

    /// Claude Code writes ~/.claude/sessions/<pid>.json with live status.
    static func claudeSessions() -> [Int32: [String: Any]] {
        let dir = "\(NSHomeDirectory())/.claude/sessions"
        var out: [Int32: [String: Any]] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".json") {
            guard let pid = Int32(f.dropLast(5)), let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(f)")),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            out[pid] = j
        }
        return out
    }

    public func scan(processes: [ProcessUsage]) -> [AgentSession] {
        let uid = getuid()
        let mine = processes.filter { $0.uid == uid }
        let byPID = Dictionary(mine.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var ppid: [Int32: Int32] = [:]
        for p in processes { ppid[p.pid] = p.ppid }
        let claude = Self.claudeSessions()
        var found: [Int32: String] = [:]
        for p in mine {
            if claude[p.pid] != nil { found[p.pid] = "Claude Code"; continue }
            // Agents are command-line tools; ignore runtimes bundled inside apps (e.g. an editor's Copilot helper).
            if p.path.contains(".app/") { continue }
            // Cheap filter before reading argv.
            let lower = p.name.lowercased()
            let candidates = ["claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "copilot", "amp", "kiro", "goose", "node", "python", "bun", "deno"]
            guard candidates.contains(where: { lower.contains($0) }) || p.path.contains("/claude/versions/") else { continue }
            let args = ProcInfo.arguments(p.pid)
            if p.path.contains("/claude/versions/") { found[p.pid] = "Claude Code"; continue }
            for s in Self.signatures where s.match(lower, args) { found[p.pid] = s.agent; break }
        }
        // Keep only top-most agent processes (drop agent processes whose ancestor is the same agent).
        let roots = found.filter { pid, agent in
            var cur = ppid[pid] ?? 1
            while cur > 1 { if found[cur] == agent { return false }; cur = ppid[cur] ?? 1 }
            return true
        }
        var sessions: [AgentSession] = []
        for (pid, agent) in roots {
            guard let p = byPID[pid] else { continue }
            let desc = ProcInfo.descendants(of: pid, ppidMap: ppid)
            let kids: [AgentSession.Child] = desc.compactMap { c in
                guard let cp = byPID[c] else { return nil }
                let ports = Sockets.sockets(of: c).filter { $0.state == "LISTEN" }.map(\.localPort)
                return AgentSession.Child(pid: c, name: cp.name, command: ProcInfo.arguments(c).joined(separator: " "), ports: Array(Set(ports)).sorted(), cpu: cp.cpu, memory: cp.memory)
            }
            let treeCPU = p.cpu + kids.reduce(0) { $0 + $1.cpu }
            var hist = cpuHistory[pid] ?? []
            hist.append(treeCPU)
            if hist.count > 6 { hist.removeFirst(hist.count - 6) }
            cpuHistory[pid] = hist
            var status = (hist.max() ?? 0) > 3 ? "Working" : "Waiting"
            var title: String?
            if let info = claude[pid] {
                if let st = info["status"] as? String { status = (st == "busy" || st == "working" || st == "running") ? "Working" : "Waiting" }
                title = info["name"] as? String
            }
            let cwd = (claude[pid]?["cwd"] as? String) ?? ProcInfo.cwd(pid)
            sessions.append(AgentSession(pid: pid, agent: agent, project: cwd.flatMap { DevServerTracker.projectRoot(for: $0) }.map { URL(fileURLWithPath: $0).lastPathComponent } ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                                         cwd: cwd, status: status, title: title, started: p.startTime, cpu: treeCPU,
                                         memory: p.memory + kids.reduce(0) { $0 + $1.memory }, children: kids,
                                         ports: Array(Set(kids.flatMap(\.ports))).sorted()))
        }
        let alive = Set(sessions.map(\.pid))
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        return sessions.sorted { ($0.agent, $0.pid) < ($1.agent, $1.pid) }
    }
}

// MARK: - Docker

public struct ContainerInfo: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var ports: String
    public var composeProject: String?
    public var composeService: String?
    public var cpuPercent: Double
    public var memUsage: String
    public var memPercent: Double
    public var netIO: String
    public var blockIO: String
}

public enum Docker {
    public static var binary: String? { Shell.which("docker") }

    public static func containers() -> (available: Bool, items: [ContainerInfo]) {
        guard let bin = binary else { return (false, []) }
        guard let ps = Shell.run(bin, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout: 6) else { return (false, []) }
        var items: [String: ContainerInfo] = [:]
        for line in ps.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let id = String((j["ID"] as? String ?? "").prefix(12))
            let labels = (j["Labels"] as? String ?? "").split(separator: ",").reduce(into: [String: String]()) { acc, kv in
                let p = kv.split(separator: "=", maxSplits: 1)
                if p.count == 2 { acc[String(p[0])] = String(p[1]) }
            }
            items[id] = ContainerInfo(id: id, name: j["Names"] as? String ?? id, image: j["Image"] as? String ?? "", state: j["State"] as? String ?? "",
                                      status: j["Status"] as? String ?? "", ports: j["Ports"] as? String ?? "",
                                      composeProject: labels["com.docker.compose.project"], composeService: labels["com.docker.compose.service"],
                                      cpuPercent: 0, memUsage: "", memPercent: 0, netIO: "", blockIO: "")
        }
        if items.values.contains(where: { $0.state == "running" }), let st = Shell.run(bin, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 10) {
            for line in st.split(separator: "\n") {
                guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                let id = String((j["ID"] as? String ?? j["Container"] as? String ?? "").prefix(12))
                guard var c = items[id] else { continue }
                c.cpuPercent = Double((j["CPUPerc"] as? String ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0
                c.memPercent = Double((j["MemPerc"] as? String ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0
                c.memUsage = j["MemUsage"] as? String ?? ""
                c.netIO = j["NetIO"] as? String ?? ""
                c.blockIO = j["BlockIO"] as? String ?? ""
                items[id] = c
            }
        }
        return (true, items.values.sorted { ($0.composeProject ?? "~", $0.name) < ($1.composeProject ?? "~", $1.name) })
    }

    @discardableResult
    public static func action(_ verb: String, _ ids: [String]) -> Bool {
        guard let bin = binary, ["stop", "start", "restart", "pause", "unpause"].contains(verb) else { return false }
        return Shell.run(bin, [verb] + ids, timeout: 60) != nil
    }
}
