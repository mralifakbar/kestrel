import Foundation
import Darwin
import Security

public struct SocketEntry: Codable, Hashable, Identifiable {
    public var id: String { "\(pid)-\(proto)-\(localAddress)-\(localPort)-\(remoteAddress)-\(remotePort)" }
    public var pid: Int32
    public var proto: String     // TCP / UDP
    public var localAddress: String
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int
    public var state: String
    public var isListening: Bool { state == "LISTEN" || (proto == "UDP" && remotePort == 0) }
}

public enum Sockets {
    static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    static func fds(_ pid: Int32) -> [proc_fdinfo] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.size + 16
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buf, Int32(count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return [] }
        return Array(buf.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size))
    }

    static func address(_ ini: in_sockinfo, local: Bool) -> String {
        let v4 = (ini.insi_vflag & UInt8(INI_IPV4)) != 0
        if v4 {
            var a = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            let s = String(cString: buf)
            return s == "0.0.0.0" ? "*" : s
        } else {
            var a = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            let s = String(cString: buf)
            return s == "::" ? "*" : s
        }
    }

    public static func sockets(of pid: Int32) -> [SocketEntry] {
        var out: [SocketEntry] = []
        for fd in fds(pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size else { continue }
            let kind = si.psi.soi_kind
            if kind == Int32(SOCKINFO_TCP) {
                let tcp = si.psi.soi_proto.pri_tcp
                let ini = tcp.tcpsi_ini
                let st = Int(tcp.tcpsi_state)
                out.append(SocketEntry(pid: pid, proto: "TCP", localAddress: address(ini, local: true), localPort: Int(UInt16(truncatingIfNeeded: ini.insi_lport).byteSwapped),
                                       remoteAddress: address(ini, local: false), remotePort: Int(UInt16(truncatingIfNeeded: ini.insi_fport).byteSwapped),
                                       state: st < tcpStates.count ? tcpStates[st] : "?"))
            } else if kind == Int32(SOCKINFO_IN), si.psi.soi_protocol == IPPROTO_UDP {
                let ini = si.psi.soi_proto.pri_in
                out.append(SocketEntry(pid: pid, proto: "UDP", localAddress: address(ini, local: true), localPort: Int(UInt16(truncatingIfNeeded: ini.insi_lport).byteSwapped),
                                       remoteAddress: address(ini, local: false), remotePort: Int(UInt16(truncatingIfNeeded: ini.insi_fport).byteSwapped), state: ""))
            }
        }
        return out
    }

    public static func openFiles(of pid: Int32) -> [String] {
        var out: [String] = []
        for fd in fds(pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, size) == size else { continue }
            let p = String(cTuple: vi.pvip.vip_path)
            if !p.isEmpty { out.append(p) }
        }
        return Array(Set(out)).sorted()
    }
}

public struct CodeSignatureInfo: Codable, Hashable {
    public var signed: Bool = false
    public var identifier: String?
    public var teamID: String?
    public var authority: String?
    public var isApple: Bool = false
    public var hardenedRuntime: Bool = false
    public var sandboxed: Bool = false
    public var notarizedOrAppStore: Bool = false
    public var summary: String {
        guard signed else { return "Unsigned" }
        if isApple { return "Apple" }
        return teamID.map { "Team \($0)" } ?? "Ad-hoc signed"
    }
}

public struct ProcessDetail: Codable {
    public var pid: Int32
    public var name: String
    public var path: String
    public var user: String
    public var parentPID: Int32
    public var parentName: String
    public var responsiblePID: Int32
    public var launchAgent: String?
    public var arguments: [String]
    public var workingDirectory: String?
    public var started: Date?
    public var userTime: Double
    public var systemTime: Double
    public var memory: UInt64
    public var peakMemory: UInt64
    public var threads: Int
    public var diskRead: UInt64
    public var diskWritten: UInt64
    public var signature: CodeSignatureInfo
    public var openFiles: [String]
    public var sockets: [SocketEntry]
    public var children: [ChildProc]

    public struct ChildProc: Codable, Hashable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
    }

    public var listeningPorts: [SocketEntry] { sockets.filter(\.isListening) }

    public var asText: String {
        var s = """
        \(name) (pid \(pid))
        Path: \(path)
        User: \(user)
        Parent: \(parentName) (\(parentPID))
        Responsible: \(responsiblePID)
        Launch agent: \(launchAgent ?? "—")
        Command: \(arguments.joined(separator: " "))
        Working directory: \(workingDirectory ?? "—")
        Started: \(started.map { ISO8601DateFormatter().string(from: $0) } ?? "—")
        CPU time: user \(String(format: "%.2f", userTime))s, system \(String(format: "%.2f", systemTime))s
        Memory: \(Fmt.bytes(memory)) (peak \(Fmt.bytes(peakMemory)))
        Threads: \(threads)
        Disk: read \(Fmt.bytes(diskRead)), written \(Fmt.bytes(diskWritten))
        Signature: \(signature.summary)\(signature.identifier.map { " — \($0)" } ?? ""); hardened runtime: \(signature.hardenedRuntime ? "yes" : "no"); sandbox: \(signature.sandboxed ? "yes" : "no")
        """
        if !listeningPorts.isEmpty { s += "\nListening: " + listeningPorts.map { "\($0.proto) \($0.localAddress):\($0.localPort)" }.joined(separator: ", ") }
        if !children.isEmpty { s += "\nChildren: " + children.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ") }
        if !openFiles.isEmpty { s += "\nOpen files (\(openFiles.count)):\n  " + openFiles.prefix(200).joined(separator: "\n  ") }
        return s
    }

    public var asCSV: String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows: [(String, String)] = [
            ("pid", "\(pid)"), ("name", name), ("path", path), ("user", user), ("parent_pid", "\(parentPID)"), ("parent", parentName),
            ("launch_agent", launchAgent ?? ""), ("command", arguments.joined(separator: " ")), ("cwd", workingDirectory ?? ""),
            ("user_time_s", String(format: "%.3f", userTime)), ("system_time_s", String(format: "%.3f", systemTime)),
            ("memory_bytes", "\(memory)"), ("peak_memory_bytes", "\(peakMemory)"), ("threads", "\(threads)"),
            ("team_id", signature.teamID ?? ""), ("signing_id", signature.identifier ?? ""), ("hardened_runtime", "\(signature.hardenedRuntime)"),
            ("sandboxed", "\(signature.sandboxed)"),
            ("listening_ports", listeningPorts.map { "\($0.proto):\($0.localPort)" }.joined(separator: " ")),
            ("children", children.map { "\($0.pid)" }.joined(separator: " ")),
            ("open_files", openFiles.joined(separator: "; ")),
        ]
        return "field,value\n" + rows.map { "\($0.0),\(q($0.1))" }.joined(separator: "\n") + "\n"
    }
}

public enum ProcessInspector {
    public static func signature(path: String) -> CodeSignatureInfo {
        var info = CodeSignatureInfo()
        guard !path.isEmpty else { return info }
        let target = AppResolver.outermostApp(path).flatMap { app in path.hasPrefix(app + "/Contents/MacOS/") ? app : nil } ?? path
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: target) as CFURL, [], &code) == errSecSuccess, let code else { return info }
        var dict: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &dict) == errSecSuccess, let d = dict as? [String: Any] else { return info }
        info.identifier = d[kSecCodeInfoIdentifier as String] as? String
        info.signed = info.identifier != nil
        info.teamID = d[kSecCodeInfoTeamIdentifier as String] as? String
        if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first {
            info.authority = SecCertificateCopySubjectSummary(first) as String?
        }
        let csFlags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        info.hardenedRuntime = (csFlags & 0x10000) != 0
        if let ent = d[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            info.sandboxed = ent["com.apple.security.app-sandbox"] as? Bool ?? false
        }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req {
            info.isApple = SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        if !info.isApple, SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists or anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists" as CFString, [], &req) == errSecSuccess, let req {
            info.notarizedOrAppStore = SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        return info
    }

    private static var launchIndex: [String: String]?
    private static let lock = NSLock()

    /// Finds the launchd plist (agent or daemon) whose Program / ProgramArguments point at `path`.
    public static func launchAgent(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if launchIndex == nil {
            var idx: [String: String] = [:]
            let dirs = ["\(NSHomeDirectory())/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
                        "/System/Library/LaunchAgents", "/System/Library/LaunchDaemons"]
            for dir in dirs {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                    let full = "\(dir)/\(f)"
                    guard let d = NSDictionary(contentsOfFile: full) as? [String: Any] else { continue }
                    let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
                    if let prog { idx[prog] = full }
                    if let bp = d["BundleProgram"] as? String { idx[bp] = full }
                }
            }
            launchIndex = idx
        }
        if let hit = launchIndex?[path] { return hit }
        return launchIndex?.first(where: { path.hasSuffix("/" + $0.key) })?.value
    }

    public static func detail(pid: Int32) -> ProcessDetail? {
        guard let raw = ProcInfo.raw(pid) else { return nil }
        let pw = getpwuid(raw.uid)
        let user = pw.map { String(cString: $0.pointee.pw_name) } ?? "\(raw.uid)"
        let ppidMap = Dictionary(uniqueKeysWithValues: ProcInfo.allPIDs().compactMap { p in ProcInfo.bsdInfo(p).map { (p, Int32($0.pbi_ppid)) } })
        let children = ppidMap.filter { $0.value == pid }.keys.sorted().map { ProcessDetail.ChildProc(pid: $0, name: ProcInfo.raw($0)?.name ?? ProcessNames.name($0)) }
        let args = ProcInfo.arguments(pid)
        return ProcessDetail(pid: pid, name: raw.name, path: raw.path, user: user, parentPID: raw.ppid, parentName: ProcessNames.name(raw.ppid),
                             responsiblePID: k_responsible_pid_safe(pid), launchAgent: raw.ppid == 1 ? launchAgent(for: raw.path) : nil,
                             arguments: args.isEmpty ? [raw.path] : args, workingDirectory: ProcInfo.cwd(pid), started: raw.startTime,
                             userTime: raw.userNs / 1e9, systemTime: raw.systemNs / 1e9, memory: raw.footprint, peakMemory: raw.peakFootprint,
                             threads: raw.threads, diskRead: raw.diskRead, diskWritten: raw.diskWrite, signature: signature(path: raw.path),
                             openFiles: Sockets.openFiles(of: pid), sockets: Sockets.sockets(of: pid), children: children)
    }
}

import CKestrel
func k_responsible_pid_safe(_ pid: Int32) -> Int32 { k_responsible_pid(pid) }
