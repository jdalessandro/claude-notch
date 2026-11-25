import AppKit
import ClaudeNotchCore
import UserNotifications

enum Notifier {
    /// UNUserNotificationCenter crashes for processes without a bundle (plain `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(kind: SessionStore.NotifyKind, session s: AgentSession, sound: Bool, banner: Bool, details: Bool) {
        let (title, body): (String, String) =
            switch kind {
            case .permission:
                ("Approval needed · \(s.projectName)", s.pending?.summary ?? s.attentionMessage ?? "Claude is asking for permission")
            case .input: ("Waiting for you · \(s.projectName)", s.attentionMessage ?? "Claude is waiting for your input")
            case .finished: ("Done · \(s.projectName)", String((s.lastMessage ?? s.displayTitle).prefix(140)))
            case .failed: ("Turn failed · \(s.projectName)", s.attentionMessage ?? "Claude hit an error")
            }
        if sound { (kind == .finished ? NSSound(named: "Glass") : NSSound(named: "Funk"))?.play() }
        guard banner, available else { return }
        let generic: String =
            switch kind {
            case .permission: "Claude is asking for permission"
            case .input: "Claude is waiting for your input"
            case .finished: "The turn finished"
            case .failed: "Claude hit an error"
            }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = details ? body : generic
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
