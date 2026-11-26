import ActivityKit
import AppKit
import ClaudeNotchCore
import os

private let log = Logger(subsystem: "dev.claudenotch", category: "activity")

/// Appends a line to `activity.log` in Application Support (Unified Logging is not always readable from a terminal),
/// so the island's lifecycle can be verified. Capped, and contains no prompt or command text.
func activityTrace(_ line: String) {
    let url = Paths.supportDir.appendingPathComponent("activity.log")
    let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 100_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(text.utf8)); try? h.close()
    } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Owns the single Live Activity that is the island. Everything it shows comes from `NotchActivityState`.
///
/// Platform rules learned in the spike:
/// - starting an activity needs the app in the foreground (`visibility` error), updating does not;
/// - so it starts at launch / on demand, is adopted again after a relaunch, and is never ended just because things are idle.
@MainActor
final class ActivityHost {
    private(set) var activity: Activity<NotchAttributes>?
    private(set) var lastError: String?
    private var last: NotchActivityState?
    private var lastAlertKey: String?

    var isLive: Bool { activity != nil }
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Re-attaches to an activity that survived a relaunch (ending duplicates) instead of stacking a second one.
    func adoptExisting() {
        let existing = Activity<NotchAttributes>.activities
        activity = existing.first
        activityTrace("adopted \(existing.count) existing activities")
        for extra in existing.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Starts the activity if there is none. Returns whether one is live afterwards.
    @discardableResult
    func ensureStarted(with state: NotchActivityState) -> Bool {
        if activity != nil { return true }
        guard enabled else { lastError = "Live Activities are turned off for Claude Notch in System Settings."; return false }
        do {
            activity = try Activity.request(
                attributes: NotchAttributes(title: "Claude Notch"), content: .init(state: state, staleDate: nil), pushType: nil,
                style: .standard)
            last = state
            lastError = nil
            activityTrace("started"); log.notice("started \(self.activity?.id ?? "?", privacy: .public)")
            return true
        } catch {
            let e = error as NSError
            lastError = "\(e.domain) \(e.code): \(e.localizedDescription)"
            activityTrace("start failed \(lastError ?? "")"); log.error("start failed \(self.lastError ?? "", privacy: .public)")
            return false
        }
    }

    /// Pushes a new state. `alert` re-expands the island (used when something new needs the user).
    func push(_ state: NotchActivityState, alert: (title: String, body: String, sound: Bool)? = nil) {
        guard let activity else { return }
        if state == last, alert == nil { return }
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        let key = alert.map { "\($0.title)|\($0.body)" }
        Task {
            if let alert, key != lastAlertKey {
                lastAlertKey = key
                await activity.update(
                    content,
                    alertConfiguration: AlertConfiguration(
                        title: LocalizedStringResource(stringLiteral: alert.title),
                        body: LocalizedStringResource(stringLiteral: alert.body), sound: alert.sound ? .default : .named("silence")))
            } else {
                await activity.update(content)
            }
        }
    }

    func end() async {
        guard let a = activity else { return }
        await a.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }
}
