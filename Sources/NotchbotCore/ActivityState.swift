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

    /// One session line under the featured prompt.
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: Kind
        public var detail: String
        /// When the current turn started, for a system-updated timer. Nil when not working.
        public var since: Date?
        /// Running subagents, and all subagents this session has started.
        public var subagents: Int
        public var subagentTotal: Int
        public var tokens: Int
        /// Context window used, 0...1 (rounded to whole percent to keep updates rare); nil when the window is unknown.
        public var context: Double?
        /// The live request this row can answer inline (Allow / Deny, or Answer for a question); nil when none.
        public var requestId: String?
        public var branch: String?
        public var linesAdded: Int
        public var linesRemoved: Int
        /// The tool a pending request is for ("Bash"), and whether a subagent asked.
        public var tool: String?
        public var fromSubagent: Bool
        /// The pending command is high-risk, or too long for the inline row: show the full card before Allow / Deny.
        public var destructive = false
        public var truncated = false
        public var reviewFirst: Bool { requestId != nil && (destructive || truncated) }
    }

    /// The most urgent request, shown as a card: a tool permission (Allow / Deny) or Claude asking a question.
    public struct Prompt: Codable, Hashable, Sendable {
        public var sessionId: String
        public var requestId: String
        public var session: String
        public var tool: String
        /// The command / file for a permission, the question text for a question.
        public var text: String
        public var isQuestion: Bool
        public var header: String?
        /// The question's choices (read-only: the answer is given in Claude).
        public var options: [String]
        public var moreOptions: Int
        public var multiSelect: Bool
        /// Further questions in the same tool call.
        public var moreQuestions: Int
        /// The subagent type when a subagent asked.
        public var subagent: String?
        /// False when no hook is waiting for our answer: only "Open" is offered.
        public var canAnswer: Bool
        public var branch: String?
        public var destructive = false
        /// What "Allow for session" would cover ("npm install"); nil when the option isn't offered (never for a
        /// destructive command).
        public var sessionScope: String?
    }

    public enum Phase: String, Codable, Sendable { case idle, working, needsYou, done }

    public var phase: Phase
    public var headline: String
    public var sessions: Int
    public var needsYou: Int
    public var working: Int
    public var subagentsRunning: Int
    public var prompt: Prompt?
    public var rows: [Row]
    /// Sessions that did not fit (neither the prompt nor `rows`).
    public var more: Int
    /// Used fraction (0...1) of the 5-hour and weekly plan windows; nil when unknown.
    public var fiveHour: Double?
    public var weekly: Double?
    /// Waveform beat, advanced by the app about once a second while agents run (see `isAnimated`).
    public var pulse = 0
    /// When the 5-hour and weekly windows reset; nil when unknown.
    public var fiveHourReset: Date?
    public var weeklyReset: Date?
    /// The session list is paged (a Live Activity can't scroll): which page is shown, of how many.
    public var page = 0
    public var pages = 1
    /// Type and icon size multiplier chosen in settings (1 = default); the widget process can't read the app's settings.
    public var scale = 1.0
    /// Finished sessions waiting for the user to review; shown as a badge on the logo. The app zeroes it when the
    /// setting is off, since the widget process can't read the app's settings.
    public var reviews = 0
    /// Why the limits are missing or not current; nil when they are simply shown. Absent from the payload when nil.
    public var limitsNote: LimitsNote?
    /// True when NotchBot's hooks are not installed, so "no sessions" cannot be told apart from "not watching".
    public var hooksMissing = false

    /// The state of the plan-limit fetch, set by the app.
    public enum LimitsNote: String, Codable, Sendable {
        /// A fetch is running.
        case refreshing
        /// The last fetch failed (any limits shown are the last known).
        case failed
        /// No limits exist for this account (an API-billed account has no plan windows), so none are promised.
        case notApplicable
    }

    /// True when neither plan window is known.
    public var limitsUnknown: Bool { fiveHour == nil && weekly == nil }
    /// The subagent tree being shown in place of the session rows, when the user tapped a session's subagent pill.
    public var focus: Focus?
    /// Whether the subagent pill opens the tree (the "Subagents" display setting; the widget can't read it).
    public var subagentTree = true

    /// Whether the waveform has bars to move.
    public var isAnimated: Bool { working + subagentsRunning > 0 || phase == .needsYou }

    /// Session cards per page, and per page under a request card (which is tall).
    public static let maxRows = 3
    public static let maxRowsWithPrompt = 1
    public static let maxOptions = 4
    /// Hard ceiling for the encoded state; ActivityKit rejects larger payloads.
    public static let byteBudget = 3_500

    public static let idle = NotchActivityState(
        phase: .idle, headline: "Idle", sessions: 0, needsYou: 0, working: 0, subagentsRunning: 0, prompt: nil, rows: [],
        more: 0, fiveHour: nil, weekly: nil)

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

    /// The row's second line, as the old compact view phrased it.
    static func detail(of s: AgentSession, kind k: Kind) -> String {
        // Badges carry the kind, tool and subagent, so the text is only the substance: the command, the question,
        // the result.
        if let p = s.pending {
            if let q = p.question { return q.text }
            return p.summary.hasPrefix(p.toolName + ": ") ? String(p.summary.dropFirst(p.toolName.count + 2)) : p.summary
        }
        switch k {
        case .input, .failed: return Fmt.plainText(s.attentionMessage ?? s.activity)
        case .review: return Fmt.plainText(s.lastMessage ?? "Finished")
        case .idle: return s.lastMessage.map(Fmt.plainText) ?? "Nothing running"
        default: return s.activity
        }
    }

    static func prompt(for s: AgentSession) -> Prompt? {
        guard let p = s.pending else { return nil }
        let q = p.question
        let opts = q?.options ?? []
        // The card already names the tool, so "Bash: npm install" reads as just the command.
        var text = q?.text ?? p.summary
        if q == nil, text.hasPrefix(p.toolName + ": ") { text = String(text.dropFirst(p.toolName.count + 2)) }
        return Prompt(
            sessionId: s.id, requestId: p.id.uuidString, session: clip(s.displayTitle, 32), tool: clip(p.toolName, 24),
            text: clip(text, 200), isQuestion: p.isQuestion, header: q?.header.map { clip($0, 20) },
            options: opts.prefix(maxOptions).map { clip($0, 22) }, moreOptions: max(0, opts.count - maxOptions),
            multiSelect: q?.multiSelect ?? false, moreQuestions: max(0, (q?.total ?? 1) - 1),
            subagent: p.agentType.map { clip($0, 20) }, canAnswer: p.canAnswer, branch: s.displayBranch.map { clip($0, 22) },
            destructive: p.destructive,
            sessionScope: p.canAnswer && p.sessionRule != nil && !p.destructive ? p.sessionScope.map { clip($0, 28) } : nil)
    }

    /// Builds the activity state from the live sessions (already ordered most-urgent first by `SessionStore.active`).
    public static func make(
        sessions: [AgentSession], quota: QuotaState?, maxRows: Int = NotchActivityState.maxRows, page: Int = 0,
        featuredRequestId: String? = nil, focus: String? = nil, limitsNote: LimitsNote? = nil, hooksInstalled: Bool = true
    ) -> NotchActivityState {
        var st = build(
            sessions: sessions, quota: quota, maxRows: maxRows, page: page, featuredRequestId: featuredRequestId,
            focus: focus)
        st.limitsNote = limitsNote
        st.hooksMissing = !hooksInstalled
        return st
    }

    private static func build(
        sessions: [AgentSession], quota: QuotaState?, maxRows: Int, page: Int, featuredRequestId: String?,
        focus: String?
    ) -> NotchActivityState {
        let active = sessions.filter { $0.status != .ended }
        guard !active.isEmpty else {
            var s = NotchActivityState.idle
            s.fiveHour = quota?.fiveHour?.fraction
            s.weekly = quota?.sevenDay?.fraction
            s.fiveHourReset = quota?.fiveHour?.resetsAt
            s.weeklyReset = quota?.sevenDay?.resetsAt
            return s
        }
        let needs = active.filter { $0.status.needsAttention || $0.needsReview }
        let working = active.filter { $0.status == .working || $0.status == .compacting }
        // Answerable requests first: those are the ones the island can settle.
        // A request the user asked to see in full ("Review") takes the card while it is still live.
        let chosen = featuredRequestId.flatMap { id in active.first { $0.pending?.id.uuidString == id } }
        let featured = chosen ?? active.first { $0.pending?.canAnswer == true } ?? active.first { $0.pending != nil }
        let prompt = featured.flatMap(prompt(for:))
        let limit = prompt == nil ? maxRows : min(maxRows, maxRowsWithPrompt)
        let rest = active.filter { $0.id != featured?.id }
        // Pages wrap around, so "next" on the last page returns to the first.
        let pages = max(1, (rest.count + limit - 1) / limit)
        let current = ((page % pages) + pages) % pages
        let rows = rest.dropFirst(current * limit).prefix(limit).map { s -> Row in
            let k = kind(of: s)
            return Row(
                id: s.id, name: clip(s.displayTitle, 32), kind: k, detail: clip(detail(of: s, kind: k), 90),
                since: k == .working ? s.workingSince : nil, subagents: s.runningSubagents, subagentTotal: s.subagents.count,
                tokens: s.usage.work, context: s.contextFraction.map { ($0 * 100).rounded() / 100 },
                requestId: s.pending?.canAnswer == true ? s.pending?.id.uuidString : nil,
                branch: s.displayBranch.map { clip($0, 22) }, linesAdded: s.linesAdded, linesRemoved: s.linesRemoved,
                tool: s.pending.map { clip($0.isQuestion ? "Question" : $0.toolName, 16) }, fromSubagent: s.pending?.agentId != nil,
                destructive: s.pending?.destructive ?? false, truncated: (s.pending?.commandLength ?? 0) > CommandRisk.inlineLimit)
        }
        // A focused session's subagent tree replaces the session rows. A session that is gone or has no subagents
        // falls back to the list (the app then drops the focus).
        let focused = focus.flatMap { id in active.first { $0.id == id && !$0.subagents.isEmpty } }.map {
            Self.focus(on: $0, maxLines: prompt == nil ? maxTreeLines : maxTreeLinesWithPrompt)
        }
        let phase: Phase = !needs.isEmpty ? .needsYou : (!working.isEmpty ? .working : .done)
        let headline: String =
            switch phase {
            case .needsYou: needs.count == 1 ? "1 needs you" : "\(needs.count) need you"
            case .working: working.count == 1 ? "1 working" : "\(working.count) working"
            default: "All done"
            }
        return NotchActivityState(
            phase: phase, headline: headline, sessions: active.count, needsYou: needs.count, working: working.count,
            subagentsRunning: active.reduce(0) { $0 + $1.runningSubagents }, prompt: prompt, rows: focused == nil ? Array(rows) : [],
            more: max(0, rest.count - rows.count), fiveHour: quota?.fiveHour?.fraction, weekly: quota?.sevenDay?.fraction,
            pulse: 0, fiveHourReset: quota?.fiveHour?.resetsAt, weeklyReset: quota?.sevenDay?.resetsAt, page: current,
            pages: pages, reviews: active.filter(\.needsReview).count, focus: focused)
    }

    /// Encoded size in bytes (what ActivityKit measures).
    public var encodedSize: Int { (try? JSONEncoder().encode(self).count) ?? Int.max }
}
