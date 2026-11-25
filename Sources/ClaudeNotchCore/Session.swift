import Foundation

public enum AgentStatus: String, Sendable, Codable, Equatable {
    case working  // model/tool activity in progress
    case compacting
    case needsPermission  // blocked on a tool-permission prompt
    case needsInput  // idle prompt / elicitation: Claude is waiting on the human
    case done  // turn finished, waiting for next prompt
    case failed  // turn ended on an API error
    case ended  // session closed

    /// Sort weight: things that need a human float to the top.
    public var urgency: Int {
        switch self {
        case .needsPermission: 5
        case .needsInput: 4
        case .failed: 3
        case .working, .compacting: 2
        case .done: 1
        case .ended: 0
        }
    }
    public var needsAttention: Bool {
        self == .needsPermission || self == .needsInput || self == .failed
    }
}

public struct Subagent: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case running, done }
    public var id: String
    public var type: String
    public var description: String?
    public var status: Status = .running
    public var currentDetail: String?
    public var toolCalls = 0
    public var startedAt: Date
    public var endedAt: Date?
    public var lastMessage: String?
    public var lastEventAt: Date?
    /// When we last heard from this subagent (any of its events).
    public var lastSeen: Date { lastEventAt ?? startedAt }
    public var label: String { description ?? type }
}

/// A question Claude asked the user (the `AskUserQuestion` tool), parsed out of the request so it can be shown
/// as a question with its choices instead of as a tool name.
public struct AskedQuestion: Sendable, Equatable {
    public var header: String?
    public var text: String
    public var options: [String]
    public var multiSelect: Bool
    /// How many questions the tool call contains (the first is shown).
    public var total: Int

    public static let toolName = "AskUserQuestion"

    public static func parse(_ input: JSONValue?) -> AskedQuestion? {
        guard case .array(let qs)? = input?["questions"], let first = qs.first, let text = first["question"]?.stringValue,
            !text.isEmpty
        else { return nil }
        var options: [String] = []
        if case .array(let opts)? = first["options"] {
            for o in opts {
                if let label = o["label"]?.stringValue ?? o.stringValue, !label.isEmpty { options.append(label) }
            }
        }
        var multi = false
        if case .bool(let b)? = first["multiSelect"] { multi = b }
        return AskedQuestion(header: first["header"]?.stringValue, text: text, options: options, multiSelect: multi, total: qs.count)
    }
}

public struct PendingPermission: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var toolName: String
    public var summary: String
    public var message: String?
    /// Set when the request comes from a subagent rather than the main agent.
    public var agentType: String?
    public var agentId: String?
    public var toolUseId: String?
    /// True when a hook process is blocked waiting for our answer (we can approve from the notch).
    public var canAnswer: Bool
    public var since: Date
    /// Set when this "permission" is really Claude asking the user a question.
    public var question: AskedQuestion?
    public var isQuestion: Bool { question != nil || toolName == AskedQuestion.toolName }

    /// Whether `event` means this request has been settled elsewhere (answered in the terminal, tool ran,
    /// turn ended). Deliberately narrow: unrelated events such as the `Notification` that Claude Code fires
    /// right after a permission request, or another tool starting in parallel, must NOT resolve it.
    public func isResolved(by event: String, payload p: HookPayload) -> Bool {
        switch event {
        case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd", "PermissionDenied": return true
        case "PostToolUse", "PostToolUseFailure":
            if let a = toolUseId, let b = p.toolUseId { return a == b }
            return agentId == p.agentId
        default: return false
        }
    }
}

public struct AgentSession: Sendable, Identifiable, Equatable {
    public var id: String  // Claude session_id
    public var cwd: String
    public var status: AgentStatus = .done
    public var title: String?
    public var lastPrompt: String?
    /// Final assistant text of the last finished turn (from the Stop hook).
    public var lastMessage: String?
    public var currentTool: String?
    public var currentToolDetail: String?
    public var attentionMessage: String?
    public var pending: PendingPermission?
    public var transcriptPath: String?
    public var model: String?
    public var gitBranch: String?
    public var entrypoint: String?  // "cli", "claude-desktop", ...
    public var termProgram: String?
    public var pid: Int32?
    public var permissionMode: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var workingSince: Date?
    public var lastTurnDuration: TimeInterval?
    /// Finished/needs-attention state the user has not looked at yet.
    public var unseen = false
    public var toolCalls = 0
    public var subagents: [String: Subagent] = [:]
    /// The main agent's turn has ended (Stop). Background subagents can still be running after this.
    public var mainTurnEnded = false
    /// Descriptions of Task/Agent tool calls not yet matched to a started subagent.
    var taskQueue: [String] = []
    public var orderedSubagents: [Subagent] { subagents.values.sorted { $0.startedAt < $1.startedAt } }
    /// For the tree: what is running now first (oldest first), then finished ones, most recently finished first.
    public var rankedSubagents: [Subagent] {
        let all = subagents.values
        let running = all.filter { $0.status == .running }.sorted { $0.startedAt < $1.startedAt }
        let done = all.filter { $0.status == .done }.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        return running + done
    }
    public var runningSubagents: Int { subagents.values.filter { $0.status == .running }.count }
    mutating func takeTaskDescription() -> String? { taskQueue.isEmpty ? nil : taskQueue.removeFirst() }
    // Usage (from transcript)
    public var usage = TokenUsage()
    public var contextTokens = 0
    public var contextWindow = 200_000
    /// Exact window size from the status line; overrides the inferred one.
    public var exactContextWindow: Int?
    public var reportedCostUSD: Double?
    public var estimatedCostUSD: Double = 0
    public var linesAdded = 0
    public var linesRemoved = 0

    public var costUSD: Double { reportedCostUSD ?? estimatedCostUSD }
    public var contextFraction: Double { min(1, Double(contextTokens) / Double(max(1, contextWindow))) }
    /// A readable name for where the session runs: the repository for a Claude worktree, a friendly label for the
    /// app's scratch workspaces, otherwise the folder name.
    public var projectName: String {
        let parts = (cwd as NSString).pathComponents
        if let i = parts.firstIndex(of: ".claude"), i > 0, i + 1 < parts.count, parts[i + 1] == "worktrees" { return parts[i - 1] }
        if parts.contains("scratch-workspaces") { return "Scratch workspace" }
        return (cwd as NSString).lastPathComponent
    }
    /// The git branch, or nil when it carries no information (empty, or a detached "HEAD").
    public var displayBranch: String? {
        guard let b = gitBranch, !b.isEmpty, b != "HEAD" else { return nil }
        return b
    }
    /// The session's name: Claude's generated/custom title, else the project folder. The prompt is shown separately.
    public var displayTitle: String { title ?? projectName }
}

/// Pure reducer: hook events in, session list out. No I/O, so it is fully unit-testable.
public struct SessionStore: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public init() {}

    /// Sessions sorted for display: urgent first, then most recently active.
    public var ordered: [AgentSession] {
        sessions.values.sorted {
            $0.status.urgency != $1.status.urgency
                ? $0.status.urgency > $1.status.urgency
                : $0.lastEventAt > $1.lastEventAt
        }
    }
    public var active: [AgentSession] { ordered.filter { $0.status != .ended } }
    public var attentionCount: Int { active.filter { $0.status.needsAttention || $0.unseen }.count }
    public var workingCount: Int { active.filter { $0.status == .working || $0.status == .compacting }.count }

    public enum Effect: Equatable, Sendable {
        case none
        case notify(sessionId: String, kind: NotifyKind)
    }
    public enum NotifyKind: String, Sendable { case permission, input, finished, failed }

    @discardableResult
    public mutating func apply(_ env: HookEnvelope) -> Effect {
        let p = env.payload
        guard let sid = p.sessionId, !sid.isEmpty else { return .none }
        let now = env.receivedAt
        var s = sessions[sid] ?? AgentSession(id: sid, cwd: p.cwd ?? "", startedAt: now, lastEventAt: now)
        if let cwd = p.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let t = p.transcriptPath { s.transcriptPath = t }
        if let m = p.model { s.model = m }
        if let pm = p.permissionMode { s.permissionMode = pm }
        if let tp = env.termProgram { s.termProgram = tp }
        if let pid = env.pid { s.pid = pid }
        s.lastEventAt = now
        var effect = Effect.none
        let event = p.hookEventName ?? ""

        // Events fired from inside a subagent update that subagent only; they must not clobber the
        // parent session's status (PermissionRequest/Notification still surface on the session).
        if let aid = p.agentId, !aid.isEmpty,
            !["SubagentStart", "SubagentStop", "PermissionRequest", "Notification"].contains(event)
        {
            var sub =
                s.subagents[aid]
                ?? Subagent(
                    id: aid, type: p.agentType ?? "agent",
                    description: s.takeTaskDescription(), startedAt: now)
            switch event {
            case "PreToolUse":
                sub.currentDetail = Self.summarize(tool: p.toolName, input: p.toolInput); sub.toolCalls += 1
            case "PostToolUse", "PostToolUseFailure":
                sub.currentDetail = nil
                if let pend = s.pending, pend.isResolved(by: event, payload: p) {
                    s.pending = nil; s.attentionMessage = nil
                    if s.status == .needsPermission { s.status = .working }
                }
            default: break
            }
            sub.lastEventAt = now
            s.subagents[aid] = sub
            sessions[sid] = s
            return .none
        }

        switch event {
        case "SessionStart":
            if p.source == "compact", s.workingSince != nil {
                s.status = .working  // compaction finished mid-turn; keep working
            } else {
                s.status = .done; s.unseen = false; s.pending = nil; s.currentTool = nil
            }

        case "SubagentStart":
            if let aid = p.agentId, !aid.isEmpty, s.subagents[aid] == nil {
                s.subagents[aid] = Subagent(
                    id: aid, type: p.agentType ?? "agent",
                    description: s.takeTaskDescription(), startedAt: now)
            }

        case "SubagentStop":
            if let aid = p.agentId, !aid.isEmpty {
                var sub = s.subagents[aid] ?? Subagent(id: aid, type: p.agentType ?? "agent", startedAt: now)
                sub.status = .done
                sub.endedAt = now
                sub.lastEventAt = now
                sub.currentDetail = nil
                if let m = p.lastAssistantMessage, !m.isEmpty { sub.lastMessage = m }
                s.subagents[aid] = sub
            }
            // The main turn already ended and this was the last subagent: the work is now actually done.
            if s.mainTurnEnded, s.runningSubagents == 0, s.status != .ended {
                Self.finishTurn(&s)
                effect = .notify(sessionId: sid, kind: .finished)
            }

        case "UserPromptSubmit":
            s.subagents = [:]; s.taskQueue = []; s.mainTurnEnded = false
            s.status = .working; s.workingSince = now; s.unseen = false
            s.pending = nil; s.attentionMessage = nil
            if let pr = p.prompt, !pr.isEmpty, !Fmt.isSyntheticPrompt(pr) { s.lastPrompt = pr }

        case "PreToolUse":
            if s.workingSince == nil { s.workingSince = now }
            // In observe-only mode a new tool means the earlier prompt was settled. With a held hook the
            // request stays until it is actually answered (parallel tools must not make it vanish).
            if s.pending?.canAnswer != true {
                s.status = .working; s.pending = nil; s.attentionMessage = nil
            }
            s.currentTool = p.toolName
            s.currentToolDetail = Self.summarize(tool: p.toolName, input: p.toolInput)
            s.toolCalls += 1
            if p.toolName == "Task" || p.toolName == "Agent",
                let d = p.toolInput?["description"]?.stringValue ?? p.toolInput?["subagent_type"]?.stringValue
            {
                s.taskQueue.append(d); if s.taskQueue.count > 8 { s.taskQueue.removeFirst() }
            }

        case "PostToolUse", "PostToolUseFailure":
            if let pend = s.pending, pend.isResolved(by: event, payload: p) {
                s.pending = nil; s.attentionMessage = nil
                if s.status == .needsPermission { s.status = .working }
            } else if s.pending == nil, s.status.needsAttention || s.status == .compacting {
                s.status = .working
            }
            s.currentTool = nil; s.currentToolDetail = nil

        case "PermissionRequest":
            let alreadyAnnounced = s.status == .needsPermission && (s.pending == nil || s.pending?.toolUseId == p.toolUseId)
            s.status = .needsPermission; s.unseen = true
            let asked = p.toolName == AskedQuestion.toolName ? AskedQuestion.parse(p.toolInput) : nil
            s.pending = PendingPermission(
                id: UUID(), toolName: p.toolName ?? "tool",
                summary: asked?.text ?? Self.summarize(tool: p.toolName, input: p.toolInput) ?? (p.toolName ?? "tool"),
                message: p.message, agentType: p.agentId == nil ? nil : p.agentType, agentId: p.agentId,
                toolUseId: p.toolUseId, canAnswer: env.expectsReply, since: now, question: asked)
            s.attentionMessage = p.message
            if !alreadyAnnounced { effect = .notify(sessionId: sid, kind: .permission) }

        case "Notification" where s.status == .ended:
            break

        case "Notification":
            switch p.notificationType ?? "" {
            case "permission_prompt":
                if s.status != .needsPermission {
                    s.status = .needsPermission; s.unseen = true
                    s.attentionMessage = p.message
                    effect = .notify(sessionId: sid, kind: .permission)
                }
            case "idle_prompt", "elicitation_dialog":
                s.status = .needsInput; s.unseen = true; s.attentionMessage = p.message
                effect = .notify(sessionId: sid, kind: .input)
            default:
                // Unknown/legacy notification: infer from the text.
                let msg = (p.message ?? "").lowercased()
                if msg.contains("permission") && s.status != .needsPermission {
                    s.status = .needsPermission; s.unseen = true; s.attentionMessage = p.message
                    effect = .notify(sessionId: sid, kind: .permission)
                } else if msg.contains("waiting for your input") {
                    s.status = .needsInput; s.unseen = true; s.attentionMessage = p.message
                    effect = .notify(sessionId: sid, kind: .input)
                }
            }

        case "PreCompact":
            s.status = .compacting

        case "PostCompact":
            if s.status == .compacting { s.status = s.workingSince != nil ? .working : .done }

        case "Stop":
            s.mainTurnEnded = true
            if let w = s.workingSince { s.lastTurnDuration = now.timeIntervalSince(w) }
            s.currentTool = nil
            s.currentToolDetail = nil
            s.pending = nil
            if let m = p.lastAssistantMessage, !m.isEmpty { s.lastMessage = m }
            if s.runningSubagents > 0 {
                // Background subagents outlive the main turn. The session is still working (not idle) and the
                // "finished" notification waits for the last one to stop.
                if s.status != .needsInput { s.status = .working }
            } else {
                Self.finishTurn(&s)
                effect = .notify(sessionId: sid, kind: .finished)
            }

        case "StopFailure":
            s.status = .failed; s.unseen = true; s.workingSince = nil; s.pending = nil
            s.attentionMessage = p.message ?? p.reason
            effect = .notify(sessionId: sid, kind: .failed)

        case "SessionEnd":
            for k in s.subagents.keys where s.subagents[k]?.status == .running {
                s.subagents[k]?.status = .done; s.subagents[k]?.endedAt = now
            }
            s.status = .ended; s.workingSince = nil; s.pending = nil; s.unseen = false

        default: break  // SubagentStop etc: just refresh lastEventAt
        }
        sessions[sid] = s
        return effect
    }

    /// Marks the turn as complete: idle, unseen result waiting for review.
    static func finishTurn(_ s: inout AgentSession) {
        s.workingSince = nil
        s.currentTool = nil
        s.currentToolDetail = nil
        if s.status != .needsInput { s.status = .done }
        s.unseen = true
    }

    /// Merge transcript-derived numbers into a session.
    public mutating func applyTranscript(_ snap: TranscriptSnapshot, to id: String, prices: PriceTable) {
        guard var s = sessions[id] else { return }
        s.usage = snap.usage
        if let m = snap.model { s.model = m }
        s.contextTokens = snap.contextTokens
        s.contextWindow = s.exactContextWindow ?? contextWindow(for: s.model, observedPeak: snap.peakContextTokens)
        s.reportedCostUSD = snap.reportedCostUSD
        s.estimatedCostUSD = prices.cost(snap.usage, model: s.model)
        s.linesAdded = snap.linesAdded; s.linesRemoved = snap.linesRemoved
        if let t = snap.title { s.title = t }
        if let b = snap.gitBranch { s.gitBranch = b }
        if let e = snap.entrypoint { s.entrypoint = e }
        sessions[id] = s
    }

    public mutating func setExactContextWindow(_ size: Int, for id: String) {
        guard size > 0, sessions[id] != nil else { return }
        sessions[id]?.exactContextWindow = size; sessions[id]?.contextWindow = size
    }

    public mutating func markSeen(_ id: String) {
        guard var s = sessions[id] else { return }
        s.unseen = false
        if s.status == .needsInput || s.status == .failed { s.status = .done }
        sessions[id] = s
    }
    /// The blocked hook went away (user answered in the terminal, or it timed out).
    public mutating func detachPending(_ id: String) {
        sessions[id]?.pending?.canAnswer = false
    }

    /// Synthetic numbers for `--demo` mode and UI previews.
    public mutating func setDemoUsage(_ id: String, ctxFraction: Double, cost: Double, tokens: Int) {
        guard var s = sessions[id] else { return }
        s.contextWindow = 200_000; s.contextTokens = Int(ctxFraction * 200_000)
        s.reportedCostUSD = cost
        s.usage = TokenUsage(input: tokens / 20, output: tokens / 10, cacheRead: tokens * 8 / 10, cacheWrite: tokens / 20)
        s.model = "claude-opus-5-5"; s.gitBranch = "main"; s.workingSince = s.status == .working ? Date().addingTimeInterval(-74) : nil
        sessions[id] = s
    }

    public mutating func markAllSeen() { for id in sessions.keys { markSeen(id) } }

    /// The user answered a permission request from the notch.
    public mutating func resolvePermission(_ id: String, allowed: Bool) {
        guard var s = sessions[id] else { return }
        s.pending = nil; s.attentionMessage = nil; s.unseen = false
        s.status = .working
        sessions[id] = s
    }

    /// Drop ended sessions after `endedTTL`, and idle sessions with no events for `idleTTL`.
    /// Drops ended sessions after `endedTTL` and idle ones after `idleTTL`. A subagent silent for `subagentStale`
    /// after the main turn ended is treated as finished (it crashed or never reported a stop), so the session cannot
    /// stay "working" forever; the resulting "finished" notifications are returned for the caller to deliver.
    @discardableResult
    public mutating func prune(
        now: Date = Date(), endedTTL: TimeInterval = 120, idleTTL: TimeInterval = 12 * 3600, subagentStale: TimeInterval = 900
    ) -> [Effect] {
        var effects: [Effect] = []
        for (id, var s) in sessions where s.mainTurnEnded && s.runningSubagents > 0 {
            let running = s.subagents.values.filter { $0.status == .running }
            guard running.allSatisfy({ now.timeIntervalSince($0.lastSeen) > subagentStale }) else { continue }
            for k in s.subagents.keys where s.subagents[k]?.status == .running {
                s.subagents[k]?.status = .done
                s.subagents[k]?.endedAt = now
                s.subagents[k]?.currentDetail = nil
            }
            Self.finishTurn(&s)
            sessions[id] = s
            effects.append(.notify(sessionId: id, kind: .finished))
        }
        sessions = sessions.filter { _, s in
            let age = now.timeIntervalSince(s.lastEventAt)
            if s.status == .ended { return age < endedTTL }
            if s.pending?.canAnswer == true { return age < 900 }
            return age < idleTTL
        }
        return effects
    }

    /// Human summary of what a tool call is doing, e.g. `Bash: swift build`.
    public static func summarize(tool: String?, input: JSONValue?) -> String? {
        guard let tool else { return nil }
        func s(_ k: String) -> String? { input?[k]?.stringValue }
        let detail: String?
        switch tool {
        case "Bash": detail = s("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            detail = (s("file_path") ?? s("notebook_path")).map { ($0 as NSString).lastPathComponent }
        case "Glob", "Grep": detail = s("pattern")
        case "WebFetch": detail = s("url")
        case "WebSearch": detail = s("query")
        case "Task", "Agent": detail = s("description")
        default: detail = s("command") ?? s("file_path") ?? s("url") ?? s("query") ?? s("description")
        }
        guard let d = detail?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !d.isEmpty
        else { return tool }
        return "\(tool): \(d.count > 90 ? String(d.prefix(90)) + "…" : d)"
    }
}
