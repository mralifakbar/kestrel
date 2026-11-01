// Kestrel fan helper — runs as root via launchd socket activation.
// Accepts only: "ping", "fan <index|all> auto", "fan <index> <rpm>". RPM is clamped to the fan's own min/max.
import Foundation
import CKestrel

@_silgen_name("launch_activate_socket")
func launch_activate_socket(_ name: UnsafePointer<CChar>, _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>, _ cnt: UnsafeMutablePointer<Int>) -> Int32

func smc(_ key: String) -> Double? {
    var v = KSMCValue()
    guard ksmc_read(key, &v) == 0 else { return nil }
    var ok: Int32 = 0
    let d = ksmc_decode(&v, &ok)
    return ok != 0 ? d : nil
}

func writeU8(_ key: String, _ value: UInt8) -> Bool {
    var b = [value]
    return ksmc_write(key, &b, 1) == 0
}

func writeFloat(_ key: String, _ value: Float) -> Bool {
    var f = value
    return withUnsafeBytes(of: &f) { raw in
        var bytes = Array(raw)
        return ksmc_write(key, &bytes, UInt32(bytes.count)) == 0
    }
}

var manual = Set<Int>()

func setManual(_ i: Int, rpm: Double) -> String {
    let mn = smc("F\(i)Mn") ?? 0, mx = smc("F\(i)Mx") ?? 0
    guard mx > 0 else { return "error: no such fan" }
    let target = Float(min(max(rpm, mn), mx))
    var ok = writeU8("F\(i)Md", 1)
    if !ok { _ = writeU8("Ftst", 1); usleep(200_000); ok = writeU8("F\(i)Md", 1) }
    guard ok || smc("F\(i)Md") == nil else { return "error: SMC refused manual mode" }
    guard writeFloat("F\(i)Tg", target) else { return "error: SMC refused target" }
    manual.insert(i)
    return "ok \(Int(target))"
}

func setAuto(_ i: Int) -> String {
    _ = writeU8("F\(i)Md", 0)
    manual.remove(i)
    if manual.isEmpty { _ = writeU8("Ftst", 0) }
    return "ok auto"
}

func handle(_ line: String) -> String {
    let p = line.split(separator: " ").map(String.init)
    if p == ["ping"] { return "ok" }
    guard p.count == 3, p[0] == "fan" else { return "error: unknown command" }
    let count = Int(smc("FNum") ?? 0)
    if p[1] == "all" && p[2] == "auto" { for i in 0..<count { _ = setAuto(i) }; return "ok auto" }
    guard let i = Int(p[1]), i >= 0, i < count else { return "error: bad fan index" }
    if p[2] == "auto" { return setAuto(i) }
    guard let rpm = Double(p[2]) else { return "error: bad rpm" }
    return setManual(i, rpm: rpm)
}

func restoreAll() { for i in manual { _ = setAuto(i) } }
signal(SIGTERM) { _ in restoreAll(); exit(0) }

var fdsPtr: UnsafeMutablePointer<Int32>?
var count = 0
guard launch_activate_socket("Listener", &fdsPtr, &count) == 0, count > 0, let fds = fdsPtr else {
    FileHandle.standardError.write("Must be launched by launchd.\n".data(using: .utf8)!)
    exit(1)
}
let listener = fds[0]
var lastActivity = Date()

while true {
    var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    let r = poll(&pfd, 1, 30_000)
    if r == 0 {
        // Exit when idle and no fan is in manual mode; launchd restarts us on demand.
        if manual.isEmpty && Date().timeIntervalSince(lastActivity) > 120 { exit(0) }
        continue
    }
    guard r > 0 else { continue }
    let c = accept(listener, nil, nil)
    guard c >= 0 else { continue }
    lastActivity = Date()
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = [UInt8](repeating: 0, count: 256)
    let n = read(c, &buf, buf.count)
    if n > 0 {
        let line = String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = handle(line) + "\n"
        _ = reply.withCString { write(c, $0, strlen($0)) }
    }
    close(c)
}
