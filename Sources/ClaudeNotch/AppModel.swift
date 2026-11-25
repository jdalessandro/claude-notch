import AppKit
import ClaudeNotchCore
import Observation
import UserNotifications

/// Serializes transcript file I/O off the main thread.
/// Aggregates token usage across all local transcripts off the main thread.
actor UsageHub {
    private let agg = UsageAggregator()
    /// Token windows plus a fresh plan detection (reads config files, so it stays off the main thread).
    func refresh() -> (UsageWindows, BillingMode) { (agg.refresh(), PlanDetector.detectForCurrentUser()) }
}

actor TranscriptHub {
    private var tailers: [String: (path: String, tailer: TranscriptTailer)] = [:]
    func poll(id: String, path: String) -> TranscriptSnapshot {
        // A session can move to a new transcript file (resume/fork): never keep reading the old one.
        if let existing = tailers[id], existing.path == path { return existing.tailer.poll() }
        let t = TranscriptTailer(url: URL(fileURLWithPath: path))
        tailers[id] = (path, t)
        return t.poll()
    }
    func forget(_ id: String) { tailers[id] = nil }
}

@MainActor @Observable
final class AppModel {
    var store = SessionStore()

    init(defaults: UserDefaults = .standard) { settings = AppSettings(defaults: defaults) }

    var hovering = false { didSet { reconcile() } }
    var pinned = false { didSet { reconcile() } }
    var autoExpandUntil = Date.distantPast
    private(set) var expanded = false
    var hooksInstalled = HookInstaller.isInstalled()
    /// Hooks were installed by an older version and miss events this version relies on (for example SubagentStart).
    var hooksOutdated = false
    func refreshHookStatus() {
        hooksInstalled = HookInstaller.isInstalled()
        hooksOutdated = !HookInstaller.missingEvents(interactivePermissions: prefs.approveFromIsland).isEmpty
    }
    let settings: AppSettings
    var prefs: Preferences { settings.prefs }
    var panelWidth: CGFloat { CGFloat(prefs.panelWidth.points) }
    var onOpenSettings: (() -> Void)?
    var onPreferencesChanged: (() -> Void)?
    var lastError: String?
    var eventLog: [String] = []
    /// Offscreen rendering (`--snapshot`) cannot draw ScrollView, so it disables scrolling and the height cap.
    var snapshotMode = false
    /// Measured natural height of the expanded session list (quantized to avoid layout feedback loops).
    var listMeasured: CGFloat = 0

    // MARK: plan, quota & usage
    var billing = PlanDetector.detectForCurrentUser()
    /// Pro/Max users are metered by quota, not dollars, so `$` is hidden unless asked for.
    var showCost: Bool {
        switch prefs.costDisplay {
        case .always: true;
        case .never: false;
        case .auto: billing == .api
        }
    }
    var planDescription: String {
        switch billing {
        case .api: "API billing";
        case .subscription(let p): "\(p ?? "Subscription") (quota-based)"
        }
    }
    var planName: String? { if case .subscription(let p) = billing { return p ?? "Subscription" }; return nil }
    var usage = UsageWindows()
    var quota: QuotaState? = QuotaState.load()  // remembered from the last terminal session that reported
    /// The quota as of now: windows whose reset time has passed read as freshly reset, not as stale percentages.
    var quotaNow: QuotaState? { quota?.refreshed() }
    var statusLineInstalled = HookInstaller.isStatusLineInstalled()
    private let usageHub = UsageHub()
    private var tickCount = 0
    /// The most urgent agent; drives the collapsed island and what a click on it opens.
    var lead: AgentSession? { store.active.first }

    /// Subagents running right now across all sessions (shown in the headers).
    var runningSubagentTotal: Int { store.active.reduce(0) { $0 + $1.runningSubagents } }
    /// Sessions whose subagent tree is shown in full (the default shows the three most relevant).
    var expandedSubagents: Set<String> = []
    func toggleSubagents(_ id: String) {
        if expandedSubagents.contains(id) { expandedSubagents.remove(id) } else { expandedSubagents.insert(id) }
    }

    /// Desktop-app metadata (project folder, PRs, parent sessions), refreshed in the background. Best effort.
    var desktopIndex = DesktopSessionIndex()
    var collapsedGroups: Set<String> = []
    func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
    }
    var groups: [ProjectGroup] { ProjectGrouping.group(store.active, desktop: desktopIndex) }
    /// Active sessions in the order the island shows them: by project when grouping is on, else by urgency.
    var displayOrder: [AgentSession] {
        prefs.groupByProject ? groups.flatMap { $0.rows.map(\.session) } : store.active
    }
    private func refreshDesktopIndex() {
        Task.detached {
            let idx = DesktopSessionIndex.load()
            await MainActor.run { [weak self] in
                if self?.desktopIndex != idx { self?.desktopIndex = idx }
            }
        }
    }

    private var reviewGate = ReviewGate()

    /// Called often (from the pointer poll). A finished result counts as reviewed when the user deliberately views the
    /// full result here: pointer over the island, detailed view, for a few seconds. The island opening by itself
    /// (a notification) does not count, and neither does the compact view, which truncates the result.
    func reviewTick(now: Date = Date()) {
        var viewing: Set<String> = []
        if prefs.autoMarkReviewed, expanded, hovering, effectiveMode == .detailed {
            viewing = Set(store.active.filter { $0.needsReview }.map(\.id))
        }
        let reviewed = reviewGate.update(viewing: viewing, now: now)
        guard !reviewed.isEmpty else { return }
        for id in reviewed { store.markSeen(id) }
        reconcile()
    }

    func dismiss(_ id: String) { store.markSeen(id); reconcile() }
    func dismissAllReviewed() { store.markAllSeen(); reconcile() }

    var onExpandedChange: ((Bool) -> Void)?

    private let hub = TranscriptHub()
    private var broker = PermissionBroker()
    private var prices = PriceTable.load(from: Paths.pricingURL)
    private var server: NotchServer?
    private var timer: Timer?
    private var collapseTask: Task<Void, Never>?

    // MARK: lifecycle

    func start(demo: Bool) {
        settings.onChange = { [weak self] old, new in
            guard let self else { return }
            // The approval mode lives in settings.json, so changing it means rewriting the hook entry.
            if old.approveFromIsland != new.approveFromIsland, self.hooksInstalled { self.installHooks() }
            if new.hoverDelay != old.hoverDelay || !new.expandOnHover { self.hovering = false }
            self.reconcile()
            self.onPreferencesChanged?()
        }
        if demo { runDemo(); return }
        refreshInstalledForwarder()
        refreshHookStatus()
        let srv = NotchServer { [weak self] env, reply in
            Task { @MainActor in self?.ingest(env, reply: reply) }
        }
        do {
            try srv.start()
            server = srv
        } catch {
            lastError =
                (error as? POSIXError)?.code == .EADDRINUSE
                ? "Claude Notch is already running." : "Socket: \(error.localizedDescription)"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Notifier.requestAuthorization()
        refreshDesktopIndex()
        Task { await refreshUsage() }
    }

    private func refreshUsage() async {
        let (u, b) = await usageHub.refresh()
        usage = u
        if b != billing { billing = b }
    }
    /// Switches between the compact and detailed island; the choice persists via preferences.
    /// Set when a compact row was clicked: show the detailed view (scrolled to that session) until the island collapses.
    var forcedDetailed = false
    var focusedId: String?
    var effectiveMode: Preferences.ExpandedMode {
        Preferences.resolveExpandedMode(saved: prefs.expandedMode, forcedDetailed: forcedDetailed)
    }

    func showDetails(for id: String) {
        focusedId = id
        forcedDetailed = true
    }

    /// Header toggle. While a row-click detour is active it just goes back; otherwise it flips the saved mode.
    func toggleExpandedMode() {
        if forcedDetailed {
            forcedDetailed = false
            focusedId = nil
        } else {
            settings.prefs.expandedMode = prefs.expandedMode == .compact ? .detailed : .compact
        }
    }
    func refreshUsageNow() { Task { await refreshUsage() } }
    func openUsageSettings() { settings.tab = .integration; onOpenSettings?() }

    /// Status-line payloads carry the real quota windows (subscribers) and the exact context window.
    private func handleStatusLine(_ p: HookPayload) {
        if let q = QuotaState.parse(p.rateLimits) {
            quota = q
            q.save()
        }
        if case .number(let n)? = p.contextWindow?["context_window_size"], let sid = p.sessionId {
            store.setExactContextWindow(Int(n), for: sid)
        }
    }

    // MARK: events

    func ingest(_ env: HookEnvelope, reply: ReplyHandle?) {
        log(env)
        let sid = env.payload.sessionId ?? ""
        let name = env.payload.hookEventName ?? ""
        if name == "StatusLine" { handleStatusLine(env.payload); return }
        // Release a held hook only when this event really settles its request (see PermissionBroker).
        broker.handle(event: name, payload: env.payload, pending: store.sessions[sid]?.pending)
        if let reply {
            broker.register(reply, for: sid)
            reply.onClose = { [weak self, weak reply] in
                Task { @MainActor in
                    guard let self, let reply else { return }
                    self.broker.peerClosed(sid, sink: reply)
                    self.store.detachPending(sid)
                    self.reconcile()
                }
            }
        }
        let effect = store.apply(env)
        if let path = env.payload.transcriptPath { Task { await refreshTranscript(id: sid, path: path) } }
        if case .notify(let id, let kind) = effect, let s = store.sessions[id] {
            if prefs.shouldNotify(kind) {
                Notifier.post(
                    kind: kind, session: s, sound: prefs.soundEnabled, banner: prefs.systemNotifications, details: prefs.bannerDetails)
            }
            if kind == .permission {
                autoExpand(seconds: 600)
            } else if prefs.autoExpandOnEvents {
                autoExpand(seconds: TimeInterval(prefs.autoExpandSeconds))
            }
        }
        // Keep the UI honest: never show Allow/Deny for a request no hook is waiting on.
        if store.sessions[sid]?.pending?.canAnswer == true, !broker.hasLiveRequest(for: sid) { store.detachPending(sid) }
        if name == "SessionEnd" { Task { await hub.forget(sid) } }
        reconcile()
    }

    /// Delivers Allow/Deny to the held hook. If the hook already went away (timeout, answered in the terminal)
    /// there is nothing to answer, so the request is simply detached instead of being reported as resolved.
    /// "Answer in Claude": lets the question through (so Claude shows its own question UI), then jumps there.
    func answerQuestion(_ session: AgentSession) {
        answer(session.id, .allow)
        open(session)
    }

    func answer(_ sessionId: String, _ decision: PermissionDecision) {
        let reason = decision == .deny ? "Denied from Claude Notch" : nil
        if broker.answer(sessionId, decision, reason: reason) {
            store.resolvePermission(sessionId, allowed: decision == .allow)
        } else {
            store.detachPending(sessionId)
        }
        reconcile()
    }

    func open(_ s: AgentSession) {
        store.markSeen(s.id)
        let bundle: String? =
            if s.entrypoint?.contains("desktop") == true { "com.anthropic.claudefordesktop" } else {
                [
                    "iTerm.app": "com.googlecode.iterm2", "Apple_Terminal": "com.apple.Terminal",
                    "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm",
                    "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable",
                ][s.termProgram ?? ""]
            }
        if let b = bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
            app.activate()
        }
        reconcile()
    }

    func tick() async {
        tickCount += 1
        if tickCount % 15 == 0 { await refreshUsage() }  // every ~30 s
        if tickCount % 5 == 0 { refreshDesktopIndex() }  // every ~10 s
        let before = Set(store.sessions.keys)
        // Pruning can also finish a session whose subagents went silent; deliver that "finished" notification.
        let effects = store.prune(idleTTL: prefs.sessionRetention.seconds)
        for case .notify(let id, let kind) in effects {
            if let s = store.sessions[id], prefs.shouldNotify(kind) {
                Notifier.post(
                    kind: kind, session: s, sound: prefs.soundEnabled, banner: prefs.systemNotifications, details: prefs.bannerDetails)
            }
        }
        for gone in before.subtracting(store.sessions.keys) { await hub.forget(gone) }  // don't leak tailers of pruned sessions
        for s in store.active {
            if let p = s.transcriptPath { await refreshTranscript(id: s.id, path: p) }
        }
        reconcile()
    }

    private func refreshTranscript(id: String, path: String) async {
        let snap = await hub.poll(id: id, path: path)
        store.applyTranscript(snap, to: id, prices: prices)
    }

    // MARK: expansion

    /// Keeps the panel open for at least `seconds`. Never shortens an existing deadline: a short notice must not
    /// cut a long-lived approval request (or the demo's pinned-open state) short.
    func autoExpand(seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if until > autoExpandUntil { autoExpandUntil = until }
        collapseTask?.cancel()
        let delay = autoExpandUntil.timeIntervalSinceNow
        guard delay < 1_000_000 else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.1))
            self?.reconcile()
        }
    }

    func reconcile() {
        if store.active.isEmpty, listMeasured != 0 { listMeasured = 0 }  // an empty list must not keep a stale height
        let hasLivePrompt = store.active.contains { $0.pending?.canAnswer == true }
        let want = hovering || pinned || hasLivePrompt || Date() < autoExpandUntil
        if want != expanded {
            expanded = want
            if !want { forcedDetailed = false; focusedId = nil }  // the detour never outlives the open island
            onExpandedChange?(want)
        }
    }

    // MARK: hooks

    /// Copies the forwarder to a stable path so settings.json never points inside a movable .app.
    private func stableHookPath() throws -> String {
        let dest = Paths.supportDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appendingPathComponent("claude-notch-hook")
        let sibling = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("claude-notch-hook")
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "claude-notch-hook not found next to the app"])
        }
        // Copy beside the target, then swap in atomically: a hook firing mid-update must never find a missing or
        // half-copied binary. Also drop the quarantine flag so the copied helper isn't blocked by Gatekeeper.
        let tmp = dest.appendingPathComponent(".claude-notch-hook.\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: sibling, to: tmp)
        removexattr(tmp.path, "com.apple.quarantine", 0)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: target)
        }
        return target.path
    }

    /// settings.json points at a *copy* of the forwarder in Application Support. After an app update that copy
    /// would otherwise stay stale (an old build silently dropped status-line data), so refresh it on launch
    /// whenever hooks or the status line are installed. Only our own helper file is touched, never the user's config.
    private func refreshInstalledForwarder() {
        guard hooksInstalled || statusLineInstalled else { return }
        let target = Paths.supportDir.appendingPathComponent("bin/claude-notch-hook")
        guard let exe = Bundle.main.executableURL else { return }
        let bundled = exe.deletingLastPathComponent().appendingPathComponent("claude-notch-hook")
        guard FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: bundled.path),
            !FileManager.default.contentsEqual(atPath: bundled.path, andPath: target.path)
        else { return }
        _ = try? stableHookPath()
    }

    func installHooks() {
        do {
            _ = try HookInstaller.install(hookPath: try stableHookPath(), interactivePermissions: prefs.approveFromIsland)
            hooksInstalled = true
            refreshHookStatus()
            lastError = nil
            refreshHookStatus()
        } catch { lastError = error.localizedDescription }
    }

    /// Opt-in (user clicks "Enable quota gauges"): registers the status line so real quota % can flow in.
    func installStatusLine() {
        do {
            switch try HookInstaller.installStatusLine(hookPath: try stableHookPath()) {
            case .installed, .alreadyInstalled: statusLineInstalled = true; lastError = nil
            case .skippedExisting: lastError = "You already have a status line; left it unchanged."
            }
        } catch { lastError = error.localizedDescription }
    }

    func uninstallStatusLine() {
        do { try HookInstaller.uninstallStatusLine(); statusLineInstalled = false; lastError = nil } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            _ = try HookInstaller.uninstall(); hooksInstalled = false
            hooksOutdated = false; lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    // MARK: debug log (helps verify real payload shapes across Claude Code versions)

    private func log(_ env: HookEnvelope) {
        let p = env.payload
        eventLog.append("\(p.hookEventName ?? "?") \(p.notificationType ?? "") \(p.toolName ?? "") \(p.sessionId?.prefix(6) ?? "")")
        if eventLog.count > 200 { eventLog.removeFirst(50) }
        if prefs.logRawEvents || ProcessInfo.processInfo.environment["CLAUDE_NOTCH_LOG"] != nil,
            let d = try? env.encodedLine()
        {
            let url = Paths.supportDir.appendingPathComponent("events.jsonl")
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close()
            } else {
                try? d.write(to: url)
            }
        }
    }

    // MARK: demo

    /// Demo sessions: two of them are worktrees of another demo project, so the grouping shows.
    private func demoCwd(_ sid: String) -> String {
        switch sid {
        case "api-gateway": "/Users/you/code/payments-api/.claude/worktrees/api-gateway"
        case "docs-site": "/Users/you/code/web-dashboard/.claude/worktrees/docs-site"
        default: "/Users/you/code/\(sid)"
        }
    }

    private func runDemo() {
        func e(
            _ n: String, _ sid: String, reply: Bool = false, ago: TimeInterval = 0, _ cfg: (inout HookPayload) -> Void = { _ in }
        ) -> HookEnvelope {
            var p = HookPayload(sessionId: sid, cwd: demoCwd(sid), hookEventName: n); cfg(&p)
            return HookEnvelope(payload: p, receivedAt: Date().addingTimeInterval(-ago), termProgram: "iTerm.app", expectsReply: reply)
        }
        // payments-api: working, with two subagents (one running, one finished)
        _ = store.apply(
            e("UserPromptSubmit", "payments-api") {
                $0.prompt = "Refactor the retry logic in the payments client, add tests, and keep the public API stable"
            })
        _ = store.apply(
            e("PreToolUse", "payments-api") {
                $0.toolName = "Task"; $0.toolInput = .object(["description": .string("Map retry call sites")])
            })
        _ = store.apply(
            e("PreToolUse", "payments-api") {
                $0.toolName = "Task"; $0.toolInput = .object(["description": .string("Draft unit tests")])
            })
        _ = store.apply(
            e("SubagentStart", "payments-api", ago: 134) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        _ = store.apply(
            e("SubagentStart", "payments-api", ago: 190) {
                $0.agentId = "a2"; $0.agentType = "general-purpose"
            })
        _ = store.apply(
            e("PreToolUse", "payments-api") {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("retry\\(")])
            })
        _ = store.apply(
            e("SubagentStop", "payments-api", ago: 50) {
                $0.agentId = "a2"; $0.lastAssistantMessage = "Added 6 tests in RetryTests.swift"
            })
        _ = store.apply(
            e("PreToolUse", "payments-api") {
                $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("swift test --filter Retry")])
            })
        // web-dashboard: a subagent is asking permission
        _ = store.apply(e("UserPromptSubmit", "web-dashboard") { $0.prompt = "Fix the flaky chart tooltip" })
        _ = store.apply(
            e("SubagentStart", "web-dashboard", ago: 41) {
                $0.agentId = "w1"; $0.agentType = "general-purpose"
            })
        _ = store.apply(
            e("PermissionRequest", "web-dashboard", reply: true) {
                $0.agentId = "w1"; $0.agentType = "general-purpose"; $0.toolName = "Bash";
                $0.toolInput = .object(["command": .string("npm install --save-dev vitest")])
            })
        // api-gateway: Claude is asking the user a question
        _ = store.apply(e("UserPromptSubmit", "api-gateway") { $0.prompt = "Add an audit log for admin actions" })
        _ = store.apply(
            e("PermissionRequest", "api-gateway", reply: true) {
                $0.toolName = "AskUserQuestion"
                let opts = ["Postgres", "SQLite", "DynamoDB"].map { JSONValue.object(["label": .string($0)]) }
                let q = JSONValue.object([
                    "question": .string("Which database should store the audit log?"), "header": .string("Database"),
                    "multiSelect": .bool(false), "options": .array(opts),
                ])
                $0.toolInput = .object(["questions": .array([q])])
            })
        // infra-tools: the main turn ended, but two background subagents are still working
        _ = store.apply(e("UserPromptSubmit", "infra-tools") { $0.prompt = "Migrate the CI pipeline to the new runners" })
        _ = store.apply(
            e("PreToolUse", "infra-tools") {
                $0.toolName = "Task"; $0.toolInput = .object(["description": .string("Audit workflow files")])
            })
        _ = store.apply(
            e("PreToolUse", "infra-tools") {
                $0.toolName = "Task"; $0.toolInput = .object(["description": .string("Draft the runner config")])
            })
        _ = store.apply(
            e("SubagentStart", "infra-tools", ago: 312) {
                $0.agentId = "i1"; $0.agentType = "Explore"
            })
        _ = store.apply(
            e("SubagentStart", "infra-tools", ago: 95) {
                $0.agentId = "i2"; $0.agentType = "general-purpose"
            })
        _ = store.apply(
            e("PreToolUse", "infra-tools") {
                $0.agentId = "i1"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("runs-on")])
            })
        _ = store.apply(
            e("PreToolUse", "infra-tools") {
                $0.agentId = "i2"; $0.agentType = "general-purpose"; $0.toolName = "Write";
                $0.toolInput = .object(["file_path": .string("runners.yml")])
            })
        _ = store.apply(e("Stop", "infra-tools") { $0.lastAssistantMessage = "Started two agents on the migration." })
        // docs-site: finished, waiting for review
        _ = store.apply(e("UserPromptSubmit", "docs-site") { $0.prompt = "Write a migration guide for v2 and link it from the sidebar" })
        _ = store.apply(
            e("Stop", "docs-site") {
                $0.lastAssistantMessage =
                    "Added docs/migrating-to-v2.md covering the renamed config keys and the new retry defaults, and linked it from the sidebar under Guides."
            })
        // notes-cli: finished and already reviewed -> idle
        _ = store.apply(e("Stop", "notes-cli"))
        store.markSeen("notes-cli")
        for (id, ctx, cost, tok) in [
            ("payments-api", 0.42, 1.87, 412_000), ("web-dashboard", 0.71, 3.20, 880_000), ("docs-site", 0.18, 0.34, 96_000),
            ("notes-cli", 0.1, 0.12, 21_000), ("api-gateway", 0.33, 0.9, 150_000), ("infra-tools", 0.25, 0.7, 120_000),
        ] {
            store.setDemoUsage(id, ctxFraction: ctx, cost: cost, tokens: tok)
        }
        // Subscription plan with live quota windows, as a Max user would see.
        billing = .subscription(plan: "Max 5x"); statusLineInstalled = true
        quota = QuotaState(windows: [
            QuotaWindow(id: "five_hour", usedPercent: 82, resetsAt: Date().addingTimeInterval(4 * 3600 + 5 * 60)),
            QuotaWindow(id: "seven_day", usedPercent: 12, resetsAt: Date().addingTimeInterval(6 * 86_400 + 3600)),
            QuotaWindow(id: "seven_day_fable", usedPercent: 0, resetsAt: Date().addingTimeInterval(6 * 86_400 + 3600)),
        ])
        var u = UsageWindows()
        u.fiveHour = TokenUsage(input: 90_000, output: 310_000, cacheWrite: 700_000)
        u.today = TokenUsage(input: 210_000, output: 880_000, cacheWrite: 2_100_000)
        u.week = TokenUsage(input: 1_400_000, output: 5_200_000, cacheWrite: 11_000_000)
        usage = u
        autoExpandUntil = .distantFuture; reconcile()
    }
}
