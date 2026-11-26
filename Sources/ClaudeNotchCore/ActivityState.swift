import Foundation

extension AgentSession {
    /// One-line description of what the session is doing right now.
    public var activity: String {
        switch status {
        case .working:
            mainTurnEnded && runningSubagents > 0
                ? "Waiting on \(runningSubagents) subagent\(runningSubagents == 1 ? "" : "s")" : (currentToolDetail ?? "Thinking…")
        case .compacting: "Compacting context…"
        case .needsPermission: "Needs your approval"
        case .needsInput: "Waiting for you"
        case .done: "Done"
        case .failed: "Turn failed"
        case .ended: "Ended"
        }
    }

    /// A finished turn the user has not looked at yet.
    public var needsReview: Bool { status == .done && unseen }

    /// True only while `requestId` is the live, answerable request of this session. Lets a stale or duplicated
    /// Allow/Deny tap (the system may deliver an intent more than once) be ignored instead of answering a newer request.
    public func isAnswerable(requestId: String) -> Bool {
        guard let p = pending, p.canAnswer else { return false }
        return p.id.uuidString == requestId
    }
}

/// The compact, `Codable` snapshot pushed to the Live Activity. Everything the island shows is derived from it,
/// so the activity never reads app state and the size budget (about 4 KB) is enforced in one tested place.
public struct NotchActivityState: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case approval, question, input, failed, review, working, idle
    }

    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: Kind
        public var detail: String
        /// When the current turn started, for a system-updated timer. Nil when not working.
        public var since: Date?
        public var subagents: Int
    }

    public struct Approval: Codable, Hashable, Sendable {
        public var sessionId: String
        public var requestId: String
        public var project: String
        public var tool: String
        public var command: String
        public var fromSubagent: Bool
    }

    public enum Phase: String, Codable, Sendable { case idle, working, needsYou, done }

    public var phase: Phase
    public var headline: String
    public var needsYou: Int
    public var working: Int
    public var subagentsRunning: Int
    public var rows: [Row]
    /// Sessions that did not fit in `rows`.
    public var more: Int
    public var approval: Approval?
    /// Used fraction (0...1) of the 5-hour and weekly plan windows; nil when unknown.
    public var fiveHour: Double?
    public var weekly: Double?

    public static let maxRows = 3
    /// Hard ceiling for the encoded state; ActivityKit rejects larger payloads.
    public static let byteBudget = 3_500

    public static let idle = NotchActivityState(
        phase: .idle, headline: "Idle", needsYou: 0, working: 0, subagentsRunning: 0, rows: [], more: 0, approval: nil,
        fiveHour: nil, weekly: nil)

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }

    static func kind(of s: AgentSession) -> Kind {
        switch s.status {
        case .needsPermission: s.pending?.isQuestion == true ? .question : .approval
        case .needsInput: .input
        case .failed: .failed
        case .working, .compacting: .working
        case .done: s.needsReview ? .review : .idle
        case .ended: .idle
        }
    }

    /// Builds the activity state from the live sessions (already ordered most-urgent first by `SessionStore.active`).
    public static func make(
        sessions: [AgentSession], quota: QuotaState?, maxRows: Int = NotchActivityState.maxRows
    ) -> NotchActivityState {
        let active = sessions.filter { $0.status != .ended }
        guard !active.isEmpty else {
            var s = NotchActivityState.idle
            s.fiveHour = quota?.fiveHour?.fraction
            s.weekly = quota?.sevenDay?.fraction
            return s
        }
        let needs = active.filter { $0.status.needsAttention || $0.needsReview }
        let working = active.filter { $0.status == .working || $0.status == .compacting }
        let shown = active.prefix(maxRows)
        let rows = shown.map { s -> Row in
            let k = kind(of: s)
            let detail: String =
                switch k {
                case .approval, .question: s.pending?.summary ?? s.activity
                case .review: s.lastMessage ?? "Done"
                default: s.activity
                }
            return Row(
                id: s.id, name: clip(s.displayTitle, 28), kind: k, detail: clip(detail, 90),
                since: k == .working ? s.workingSince : nil, subagents: s.runningSubagents)
        }
        var approval: Approval?
        if let s = active.first(where: { $0.pending?.canAnswer == true && $0.pending?.isQuestion == false }), let p = s.pending {
            approval = Approval(
                sessionId: s.id, requestId: p.id.uuidString, project: clip(s.projectName, 28), tool: clip(p.toolName, 24),
                command: clip(p.summary, 160), fromSubagent: p.agentId != nil)
        }
        let phase: Phase = !needs.isEmpty ? .needsYou : (!working.isEmpty ? .working : .done)
        let headline: String =
            switch phase {
            case .needsYou: needs.count == 1 ? "1 needs you" : "\(needs.count) need you"
            case .working: working.count == 1 ? "1 working" : "\(working.count) working"
            default: "All done"
            }
        return NotchActivityState(
            phase: phase, headline: headline, needsYou: needs.count, working: working.count,
            subagentsRunning: active.reduce(0) { $0 + $1.runningSubagents }, rows: Array(rows),
            more: max(0, active.count - rows.count), approval: approval,
            fiveHour: quota?.fiveHour?.fraction, weekly: quota?.sevenDay?.fraction)
    }

    /// Encoded size in bytes (what ActivityKit measures).
    public var encodedSize: Int { (try? JSONEncoder().encode(self).count) ?? Int.max }
}
