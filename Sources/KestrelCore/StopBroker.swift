import Foundation

/// Cross-process approval for quitting things requested by the CLI / MCP server.
/// The CLI posts a request; the Kestrel app asks the user and replies.
public enum StopBroker {
    public static let requestName = Notification.Name("dev.kestrel.stop.request")
    public static let replyName = Notification.Name("dev.kestrel.stop.reply")

    public static var appIsRunning: Bool {
        ProcInfo.allPIDs().contains { pid in
            let p = ProcessNames.path(pid)
            return p.hasSuffix("/Kestrel.app/Contents/MacOS/Kestrel")
        }
    }

    /// Blocks until the user answers in the app (or timeout). Returns true when approved.
    public static func requestApproval(pids: [Int32], description: String, source: String, timeout: TimeInterval = 120) -> Bool {
        let id = UUID().uuidString
        var answer: Bool?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: replyName, object: nil, queue: nil) { note in
            guard let info = note.userInfo, info["id"] as? String == id else { return }
            answer = info["approved"] as? Bool ?? false
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(requestName, object: nil,
                                    userInfo: ["id": id, "pids": pids.map { NSNumber(value: $0) }, "description": description, "source": source],
                                    deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while answer == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        return answer ?? false
    }

    public static func reply(id: String, approved: Bool) {
        DistributedNotificationCenter.default().postNotificationName(replyName, object: nil, userInfo: ["id": id, "approved": approved], deliverImmediately: true)
    }
}
