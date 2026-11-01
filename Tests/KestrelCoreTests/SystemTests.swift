import XCTest
@testable import KestrelCore

/// Smoke tests against the real machine: they check shape, not values.
final class SystemTests: XCTestCase {
    func testCPUAndMemory() {
        let cpu = CPUSampler()
        _ = cpu.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let s = cpu.sample()
        XCTAssertFalse(s.cores.isEmpty)
        XCTAssert((0...1.0001).contains(s.total))
        let m = MemorySampler.sample()
        XCTAssertGreaterThan(m.total, 0)
        XCTAssertLessThanOrEqual(m.used, m.total + m.swapUsed)
    }

    func testProcessesAreGroupedIntoApps() {
        let p = ProcessSampler()
        p.collectNetwork = false
        let r = p.sample(cores: 1)
        XCTAssertFalse(r.processes.isEmpty)
        XCTAssertLessThan(r.apps.count, r.processes.count)
        XCTAssertEqual(r.apps.reduce(0) { $0 + $1.processCount }, r.processes.count)
    }

    func testInspectSelf() {
        let me = ProcessInfo.processInfo.processIdentifier
        let d = ProcessInspector.detail(pid: me)
        XCTAssertEqual(d?.pid, me)
        XCTAssertFalse(d?.arguments.isEmpty ?? true)
        XCTAssertTrue(d?.asCSV.hasPrefix("field,value") ?? false)
    }

    func testHistoryRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = HistoryStore(path: path)
        XCTAssertTrue(store.isOpen)
        let app = AppUsage(id: "/Applications/Test.app", name: "Test", bundlePath: nil, bundleID: nil, isSystem: false, cpu: 40, memory: 1000,
                           diskReadBps: 0, diskWriteBps: 0, netInBps: 0, netOutBps: 0, energy: 0, processCount: 1, threads: 1, pids: [1], mainPID: 1)
        store.record(metrics: ["cpu": 0.5], apps: [app], at: Date().addingTimeInterval(-120))
        store.record(metrics: ["cpu": 0.7], apps: [app], at: Date().addingTimeInterval(-60))
        let pts = store.series("cpu", since: Date().addingTimeInterval(-3600), points: 1000)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(store.topApps(since: Date().addingTimeInterval(-3600)).first?.name, "Test")
        XCTAssertEqual(store.appSeries(app.id, since: Date().addingTimeInterval(-3600), points: 1000).cpu.count, 2)
    }
}
