import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import KestrelCore

@main
struct KestrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { WindowOpener.openSettings() }.keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Open Kestrel") { WindowOpener.openMain() }.keyboardShortcut("0", modifiers: .command)
                }
                CommandMenu("Go") {
                    ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                        if i < 9 {
                            Button(s.plainTitle) { AppModel.shared.open(section: s) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                        } else {
                            Button(s.plainTitle) { AppModel.shared.open(section: s) }
                        }
                    }
                }
            }
    }
}

/// The main and settings windows are plain AppKit windows hosting SwiftUI, so they can be
/// opened from the menu bar at any time (the app usually runs without a Dock icon).
@MainActor
enum WindowOpener {
    private static var main: NSWindow?
    private static var settings: NSWindow?

    static var mainWindow: NSWindow? { main }

    static func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if main == nil {
            let host = NSHostingController(rootView: MainView()
                .environmentObject(AppModel.shared)
                .environmentObject(AudioController.shared)
                .frame(minWidth: 920, minHeight: 600))
            // Don't recompute the window's size limits on every SwiftUI update (very costly
            // with a live dashboard); the limits are fixed, so set them once.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.contentMinSize = NSSize(width: 920, height: 600)
            w.title = "Kestrel"
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1180, height: 760))
            w.setFrameAutosaveName("KestrelMain")
            if w.frame.origin == .zero { w.center() }
            main = w
        }
        main?.makeKeyAndOrderFront(nil)
        AppDelegate.updateVisibility()
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settings == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(AppModel.shared))
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Kestrel Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "showInDock": false, "palette": "colorful", "compact": false, "fastInterval": 1.0,
            "alerts.enabled": true, "alerts.cpu": true, "alerts.cpuPercent": 150.0, "alerts.cpuSeconds": 60.0,
            "alerts.memory": true, "alerts.memoryGrowthGB": 2.0, "alerts.disk": true, "alerts.diskMBps": 100.0, "alerts.diskSeconds": 30.0,
            "alerts.network": true, "alerts.networkMBps": 20.0, "alerts.networkSeconds": 60.0, "alerts.pressure": true, "alerts.temperature": false, "alerts.temperatureC": 95.0,
        ])
        applyDockPolicy()
        AppModel.shared.start()
        menuBar = MenuBarController(model: AppModel.shared)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        StopRequestListener.shared.start()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in Self.updateVisibility() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { Self.updateVisibility() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { _ in Self.updateVisibility() }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { _ in Self.updateVisibility() }
        // Development switch: KESTREL_OPEN=<section> opens the window on that section.
        if let open = ProcessInfo.processInfo.environment["KESTREL_OPEN"], let section = Section(rawValue: open) {
            AppModel.shared.open(section: section)
        }
        // Open the window on first launch (or when living in the Dock) so there's something to see.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") || UserDefaults.standard.bool(forKey: "showInDock") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            WindowOpener.openMain()
        }
    }

    @MainActor static func updateVisibility() {
        let visible = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized }
        if AppModel.shared.windowVisible != visible {
            Task { @MainActor in AppModel.shared.setWindowVisible(visible) }
        }
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: "showInDock") ? .regular : .accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.openMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AudioController.shared.teardown()
        FanControl.restoreAutoIfNeeded()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let app = info["app"] as? String { AppModel.shared.open(section: .apps, app: app) }
            else { WindowOpener.openMain() }
        }
    }
}

// MARK: - Confirmations

enum Confirm {
    @MainActor
    static func ask(_ title: String, _ message: String = "", action: String, destructive: Bool = true) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .warning : .informational
        let b = a.addButton(withTitle: action)
        if destructive { b.hasDestructiveAction = true }
        a.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func quit(pids: [Int32], name: String, force: Bool, tree: Bool = false) {
        let verb = force ? String(localized: "Force Quit") : String(localized: "Quit")
        let detail = tree ? String(localized: "This also quits everything it started.") : (pids.count > 1 ? String(localized: "\(pids.count) processes will be stopped.") : "")
        guard ask("\(verb) \(name)?", detail + (force ? "\n" + String(localized: "Unsaved changes will be lost.") : ""), action: verb) else { return }
        // Prefer a polite NSRunningApplication quit for GUI apps.
        if !force, pids.count >= 1, let app = pids.lazy.compactMap({ NSRunningApplication(processIdentifier: $0) }).first(where: { $0.activationPolicy == .regular }) {
            app.terminate()
            return
        }
        for p in pids {
            if tree { ProcessControl.terminateTree(p, force: force) } else { ProcessControl.terminate(p, force: force) }
        }
    }
}

/// Answers quit requests from the CLI / MCP server.
final class StopRequestListener {
    static let shared = StopRequestListener()
    func start() {
        DistributedNotificationCenter.default().addObserver(forName: StopBroker.requestName, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let id = info["id"] as? String else { return }
            let pids = (info["pids"] as? [NSNumber])?.map(\.int32Value) ?? []
            let desc = info["description"] as? String ?? ""
            let source = info["source"] as? String ?? "Another app"
            MainActor.assumeIsolated {
                let ok = Confirm.ask(String(localized: "\(source) wants to quit a process"), desc, action: String(localized: "Allow"))
                StopBroker.reply(id: id, approved: ok)
            }
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("Login item: \(error)") }
    }
}
