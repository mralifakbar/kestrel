import XCTest
@testable import KestrelCore

final class DevToolsTests: XCTestCase {
    func testProjectRootPrefersGitRepository() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID().uuidString)")
        let pkg = root.appendingPathComponent("apps/web")
        try fm.createDirectory(at: pkg.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        fm.createFile(atPath: pkg.appendingPathComponent("package.json").path, contents: Data("{}".utf8))
        defer { try? fm.removeItem(at: root) }

        let found = DevServerTracker.projectRoot(for: pkg.appendingPathComponent("src").path)
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, root.resolvingSymlinksInPath().path)
    }

    func testProjectRootFallsBackToMarker() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("Cargo.toml").path, contents: Data())
        defer { try? fm.removeItem(at: root) }
        XCTAssertEqual(DevServerTracker.projectRoot(for: root.path), root.path)
    }

    func testServerKind() {
        XCTAssertEqual(DevServerTracker.kind(name: "node", args: ["node", "/x/node_modules/.bin/vite", "--port", "5173"]), "Vite")
        XCTAssertEqual(DevServerTracker.kind(name: "node", args: ["node", "/x/node_modules/next/dist/bin/next", "dev"]), "Next.js")
        XCTAssertEqual(DevServerTracker.kind(name: "Python", args: ["python3", "manage.py", "runserver"]), "Django")
        XCTAssertEqual(DevServerTracker.kind(name: "myserver", args: []), "myserver")
    }

    func testGroupingPutsLooseServersLast() {
        func holder(_ pid: Int32, _ project: String?) -> PortHolder {
            PortHolder(pid: pid, name: "node", command: "", ports: [3000 + Int(pid)], addresses: [], cwd: nil, project: project,
                       projectName: project.map { URL(fileURLWithPath: $0).lastPathComponent }, cpu: 0, memory: 0, established: 0,
                       idleMinutes: 0, isIdle: false, started: nil, kind: "Node")
        }
        let groups = DevServerTracker.group([holder(1, nil), holder(2, "/p/zeta"), holder(3, "/p/alpha"), holder(4, "/p/alpha")])
        XCTAssertEqual(groups.map(\.name), ["alpha", "zeta", "Other"])
        XCTAssertEqual(groups.first?.servers.count, 2)
    }

    func testOutermostApp() {
        XCTAssertEqual(AppResolver.outermostApp("/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "/Applications/Chrome.app")
        XCTAssertNil(AppResolver.outermostApp("/usr/bin/python3"))
    }
}
