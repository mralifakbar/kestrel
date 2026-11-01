import Foundation
import AppKit
import KestrelCore

/// Talks to the optional root helper (installed as a launchd daemon) that writes fan targets to the SMC.
@MainActor
final class FanControl: ObservableObject {
    static let shared = FanControl()
    nonisolated static let socketPath = "/var/run/dev.kestrel.helper.sock"
    static let helperPath = "/Library/PrivilegedHelperTools/dev.kestrel.helper"
    static let plistPath = "/Library/LaunchDaemons/dev.kestrel.helper.plist"

    @Published var helperInstalled = FileManager.default.fileExists(atPath: FanControl.helperPath)
    @Published var lastError: String?
    private var manualFans = Set<Int>()

    func setFan(_ index: Int, rpm: Double) {
        send("fan \(index) \(Int(rpm))") { ok, msg in
            if ok { self.manualFans.insert(index) }
            self.lastError = ok ? nil : msg
        }
    }

    func setAuto(_ index: Int) {
        send("fan \(index) auto") { ok, msg in
            self.manualFans.remove(index)
            self.lastError = ok ? nil : msg
        }
    }

    static func restoreAutoIfNeeded() {
        MainActor.assumeIsolated {
            guard !shared.manualFans.isEmpty else { return }
            _ = FanControl.request("fan all auto")
        }
    }

    private func send(_ cmd: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async {
            let r = FanControl.request(cmd)
            DispatchQueue.main.async { completion(r.hasPrefix("ok"), r) }
        }
    }

    nonisolated static func request(_ cmd: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "error: socket" }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.prefix(raw.count - 1).enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { return "error: helper not running — reinstall it from Thermals" }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let line = cmd + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "error: no reply"
    }

    func installHelper() {
        guard let src = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("KestrelHelper").path,
              FileManager.default.fileExists(atPath: src) else { lastError = "Helper binary missing from the app bundle."; return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>dev.kestrel.helper</string>
          <key>Program</key><string>\(Self.helperPath)</string>
          <key>Sockets</key><dict><key>Listener</key><dict>
            <key>SockPathName</key><string>\(Self.socketPath)</string>
            <key>SockPathMode</key><integer>438</integer>
          </dict></dict>
        </dict></plist>
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dev.kestrel.helper.plist")
        do { try plist.write(to: tmp, atomically: true, encoding: .utf8) } catch { lastError = error.localizedDescription; return }
        let script = [
            "launchctl bootout system/dev.kestrel.helper 2>/dev/null || true",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp '\(src)' '\(Self.helperPath)'",
            "chown root:wheel '\(Self.helperPath)'", "chmod 755 '\(Self.helperPath)'",
            "cp '\(tmp.path)' '\(Self.plistPath)'",
            "chown root:wheel '\(Self.plistPath)'", "chmod 644 '\(Self.plistPath)'",
            "launchctl bootstrap system '\(Self.plistPath)'",
        ].joined(separator: " && ")
        runAdmin(script) { ok, err in
            self.helperInstalled = FileManager.default.fileExists(atPath: Self.helperPath)
            self.lastError = ok ? nil : err
        }
    }

    func uninstallHelper() {
        let script = "launchctl bootout system/dev.kestrel.helper 2>/dev/null; rm -f '\(Self.helperPath)' '\(Self.plistPath)' '\(Self.socketPath)'"
        runAdmin(script) { ok, err in
            self.helperInstalled = FileManager.default.fileExists(atPath: Self.helperPath)
            self.lastError = ok ? nil : err
        }
    }

    private func runAdmin(_ shell: String, completion: @escaping (Bool, String) -> Void) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Kestrel needs to install its fan helper.\""
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            DispatchQueue.main.async { completion(err == nil, (err?[NSAppleScript.errorMessage] as? String) ?? "") }
        }
    }
}
