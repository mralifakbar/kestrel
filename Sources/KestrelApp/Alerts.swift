import Foundation
import UserNotifications
import KestrelCore

/// Watches samples and posts notifications when an app misbehaves.
@MainActor
final class AlertEngine {
    static let shared = AlertEngine()
    private var cpuSince: [String: Date] = [:]
    private var diskSince: [String: Date] = [:]
    private var netSince: [String: Date] = [:]
    private var memTrail: [String: [(Date, UInt64)]] = [:]
    private var lastFired: [String: Date] = [:]
    private var pressureSince: Date?
    private var tempSince: Date?

    private var d: UserDefaults { .standard }

    func evaluate(_ s: SystemSnapshot) {
        guard d.bool(forKey: "alerts.enabled") else { return }
        let now = Date()
        let cpuLimit = d.double(forKey: "alerts.cpuPercent"), cpuSecs = d.double(forKey: "alerts.cpuSeconds")
        let diskLimit = d.double(forKey: "alerts.diskMBps") * 1_048_576, diskSecs = d.double(forKey: "alerts.diskSeconds")
        let netLimit = d.double(forKey: "alerts.networkMBps") * 1_048_576, netSecs = d.double(forKey: "alerts.networkSeconds")
        let growth = d.double(forKey: "alerts.memoryGrowthGB") * 1_073_741_824

        for a in s.apps where a.id != "kernel" {
            if d.bool(forKey: "alerts.cpu") {
                if a.cpu >= cpuLimit {
                    let since = cpuSince[a.id] ?? now
                    cpuSince[a.id] = since
                    if now.timeIntervalSince(since) >= cpuSecs {
                        fire("cpu:\(a.id)", title: "\(a.name) is using a lot of CPU", body: "\(Fmt.cpu(a.cpu, cores: s.cpu.coreCount)) for over \(Fmt.duration(now.timeIntervalSince(since))).", app: a.id)
                    }
                } else { cpuSince[a.id] = nil }
            }
            if d.bool(forKey: "alerts.disk") {
                let io = a.diskReadBps + a.diskWriteBps
                if io >= diskLimit {
                    let since = diskSince[a.id] ?? now
                    diskSince[a.id] = since
                    if now.timeIntervalSince(since) >= diskSecs { fire("disk:\(a.id)", title: "\(a.name) is hammering the disk", body: "\(Fmt.rate(io)) for over \(Fmt.duration(now.timeIntervalSince(since))).", app: a.id) }
                } else { diskSince[a.id] = nil }
            }
            if d.bool(forKey: "alerts.network") {
                let io = a.netInBps + a.netOutBps
                if io >= netLimit {
                    let since = netSince[a.id] ?? now
                    netSince[a.id] = since
                    if now.timeIntervalSince(since) >= netSecs { fire("net:\(a.id)", title: "\(a.name) is using a lot of network", body: "↓\(Fmt.rate(a.netInBps)) ↑\(Fmt.rate(a.netOutBps)) for over \(Fmt.duration(now.timeIntervalSince(since))).", app: a.id) }
                } else { netSince[a.id] = nil }
            }
            if d.bool(forKey: "alerts.memory"), !a.isSystem {
                var trail = memTrail[a.id] ?? []
                if trail.last.map({ now.timeIntervalSince($0.0) >= 15 }) ?? true { trail.append((now, a.memory)) }
                trail.removeAll { now.timeIntervalSince($0.0) > 600 }
                memTrail[a.id] = trail
                if let first = trail.first, a.memory > first.1, Double(a.memory - first.1) >= growth {
                    fire("mem:\(a.id)", title: "\(a.name) memory keeps growing", body: "Up \(Fmt.bytes(a.memory - first.1)) in \(Fmt.duration(now.timeIntervalSince(first.0))) — now \(Fmt.bytes(a.memory)).", app: a.id)
                }
            }
        }
        let live = Set(s.apps.map(\.id))
        memTrail = memTrail.filter { live.contains($0.key) }

        if d.bool(forKey: "alerts.pressure") {
            if s.memory.pressureLevel >= 4 {
                pressureSince = pressureSince ?? now
                if now.timeIntervalSince(pressureSince!) > 20 {
                    let top = s.apps.filter { !$0.isSystem }.max { $0.memory < $1.memory }
                    fire("pressure", title: "Memory pressure is critical", body: top.map { "\($0.name) is using \(Fmt.bytes($0.memory))." } ?? "", app: top?.id)
                }
            } else { pressureSince = nil }
        }
        if d.bool(forKey: "alerts.temperature"), s.thermals.cpuC > 0 {
            if s.thermals.cpuC >= d.double(forKey: "alerts.temperatureC") {
                tempSince = tempSince ?? now
                if now.timeIntervalSince(tempSince!) > 30 { fire("temp", title: "Your Mac is running hot", body: "CPU at \(Fmt.temp(s.thermals.cpuC)).", app: s.apps.first?.id) }
            } else { tempSince = nil }
        }
    }

    private func fire(_ key: String, title: String, body: String, app: String?) {
        let now = Date()
        if let last = lastFired[key], now.timeIntervalSince(last) < 30 * 60 { return }
        lastFired[key] = now
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let app { c.userInfo = ["app": app] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + "-\(now.timeIntervalSince1970)", content: c, trigger: nil))
    }
}
