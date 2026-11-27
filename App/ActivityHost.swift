import ActivityKit
import AppKit
import NotchbotCore
import os

private let log = Logger(subsystem: "dev.notchbot", category: "activity")

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
    private var stateTask: Task<Void, Never>?
    /// Content older than this reads as stale in the widget (dimmed) if the app stops updating, for example after a crash.
    private static let staleAfter: TimeInterval = 180

    /// What the system uses to rank this activity against others in the island: needing you outranks working.
    private static func relevance(_ s: NotchActivityState) -> Double {
        switch s.phase {
        case .needsYou: 100
        case .working: 50
        case .done: 20
        case .idle: 5
        }
    }

    private func content(_ s: NotchActivityState) -> ActivityContent<NotchActivityState> {
        ActivityContent(
            state: s, staleDate: Date().addingTimeInterval(Self.staleAfter), relevanceScore: Self.relevance(s))
    }

    /// Updates go out strictly in order. Separate `Task`s (a push racing a beat) can reach the system out of order, and
    /// an older state landing last leaves the island showing the wrong phase, for example no waveform while agents work.
    private var sendChain: Task<Void, Never>?
    private func send(_ run: @escaping @Sendable () async -> Void) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value; await run()
        }
    }

    /// Re-sends the current state so it does not go stale while the app is healthy.
    func heartbeat() {
        guard let activity, let last else { return }
        let c = content(last)
        send { await activity.update(c) }
    }

    /// The system (or the user, by dismissing it) can end the activity at any time; stop holding on to it.
    private func observe(_ a: Activity<NotchAttributes>) {
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            for await st in a.activityStateUpdates {
                activityTrace("state \(st)")
                if st == .ended || st == .dismissed {
                    if self?.activity?.id == a.id { self?.activity = nil }
                    break
                }
            }
        }
    }
    private var lastAlertKey: String?

    var isLive: Bool { activity != nil }
    /// What the island shows right now.
    var current: NotchActivityState? { last }
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Ends every activity left over from an earlier run. The system can keep reporting one as `active` while it is no
    /// longer on screen (for example after the user swiped it away or the app was killed), so a fresh one is requested
    /// instead of re-attaching to it.
    func resetExisting() async {
        stateTask?.cancel()
        let existing = Activity<NotchAttributes>.activities
        activityTrace("reset: ending \(existing.count) existing")
        activity = nil
        last = nil
        for a in existing { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// Starts the activity if there is none. Returns whether one is live afterwards.
    @discardableResult
    func ensureStarted(with state: NotchActivityState) -> Bool {
        if activity != nil { return true }
        guard enabled else { lastError = "Live Activities are turned off for Notchbot in System Settings."; return false }
        do {
            activity = try Activity.request(
                attributes: NotchAttributes(title: "Notchbot"), content: content(state), pushType: nil,
                style: .standard)
            last = state
            lastError = nil
            if let a = activity { observe(a) }
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
        var state = state
        state.pulse = last?.pulse ?? 0  // the beat is the host's, not the reducer's
        if state == last, alert == nil { return }
        last = state
        let content = content(state)
        let key = alert.map { "\($0.title)|\($0.body)" }
        let fire = alert != nil && key != lastAlertKey
        if fire { lastAlertKey = key }
        send {
            if let alert, fire {
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

    /// One waveform beat: re-sends the current state with the next `pulse`, which the widget animates. Only while
    /// something runs, so an idle island costs nothing.
    func beat() {
        guard let activity, var s = last, s.isAnimated else { return }
        s.pulse &+= 1
        last = s
        let content = content(s)
        send { await activity.update(content) }
    }

    func end() async {
        guard let a = activity else { return }
        stateTask?.cancel()
        await a.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }
}
