import Foundation

extension NotchActivityState {
    /// One line of the island's subagent tree: the main agent, or one subagent.
    public struct TreeLine: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Sendable { case running, waiting, done, failed }

        /// Position in the tree (0 is the main agent).
        public var id: Int
        /// "Main", or the subagent type ("Explore").
        public var name: String
        public var state: State
        /// The current tool or the description, clipped to one line.
        public var detail: String
        /// When it started, for a system-updated timer, while it runs or waits. Nil once finished.
        public var since: Date?
        /// How long it took, in whole seconds, once finished.
        public var took: Int?

        /// "Explore subagent, running, Grep in Sources, 42 seconds" — what VoiceOver reads for the line.
        public func accessibilityLabel(now: Date = Date()) -> String {
            let who = id == 0 ? "Main agent" : "\(name) subagent"
            let what: String =
                switch state {
                case .running: "running"
                case .waiting: "waiting for your approval"
                case .done: "done"
                case .failed: "failed"
                }
            let seconds = since.map { max(0, Int(now.timeIntervalSince($0))) } ?? took
            var parts = [who, what]
            if !detail.isEmpty { parts.append(detail) }
            if let seconds {
                parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
            }
            return parts.joined(separator: ", ")
        }
    }

    /// The session whose subagents the island is showing instead of the session list.
    public struct Focus: Codable, Hashable, Sendable {
        public var sessionId: String
        public var name: String
        /// The main agent, then the subagents (waiting first, then running, then finished).
        public var lines: [TreeLine]
        /// Subagents that did not fit.
        public var more: Int
        public var running: Int
        public var total: Int
    }

    /// Tree lines that fit under the header: the main agent and its subagents, and fewer under a request card.
    public static let maxTreeLines = 4
    public static let maxTreeLinesWithPrompt = 3

    static func focus(on s: AgentSession, maxLines: Int, now: Date = Date()) -> Focus {
        let waitingId = s.pending?.agentId
        let ranked = s.rankedSubagents
        // A subagent waiting on you leads, so the cap can never hide the amber line.
        let subs = ranked.filter { $0.id == waitingId } + ranked.filter { $0.id != waitingId }
        let shown = subs.prefix(max(0, maxLines - 1))

        let mainState: TreeLine.State =
            switch s.status {
            case .needsPermission where waitingId == nil, .needsInput: .waiting
            case .failed: .failed
            case .done, .ended: .done
            default: .running
            }
        var lines = [
            TreeLine(
                id: 0, name: "Main", state: mainState,
                detail: waitingId != nil ? "Waiting on a subagent" : clip(Fmt.plainText(s.activity), 44),
                since: mainState == .running || mainState == .waiting ? s.workingSince : nil,
                took: mainState == .done || mainState == .failed ? s.lastTurnDuration.map { Int($0) } : nil)
        ]
        for (i, sub) in shown.enumerated() {
            let state: TreeLine.State = sub.id == waitingId ? .waiting : (sub.status == .running ? .running : .done)
            let detail: String =
                switch state {
                case .waiting: "Needs approval" + (s.pending.map { " · " + $0.toolName } ?? "")
                case .running: sub.currentDetail ?? sub.description ?? "Working…"
                default: sub.lastMessage.map(Fmt.plainText) ?? sub.description ?? "Done"
                }
            lines.append(
                TreeLine(
                    id: i + 1, name: clip(sub.type, 16), state: state, detail: clip(detail, 44),
                    since: sub.status == .running ? sub.startedAt : nil,
                    took: sub.status == .done ? sub.endedAt.map { max(0, Int($0.timeIntervalSince(sub.startedAt))) } : nil))
        }
        return Focus(
            sessionId: s.id, name: clip(s.displayTitle, 32), lines: lines, more: max(0, subs.count - shown.count),
            running: s.runningSubagents, total: s.subagents.count)
    }
}
