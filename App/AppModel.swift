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
    var store: SessionStore = {
        var s = SessionStore(); s.windowCache = ContextWindowCache.load(); s.catalog = ModelCatalog.load(); return s
    }()

    init(defaults: UserDefaults = .standard) { settings = AppSettings(defaults: defaults) }

    var hooksInstalled = HookInstaller.isInstalled()
    /// Hooks were installed by an older version and miss events this version relies on (for example SubagentStart).
    var hooksOutdated = false
    func refreshHookStatus() {
        hooksInstalled = HookInstaller.isInstalled()
        hooksOutdated = !HookInstaller.missingEvents(interactivePermissions: prefs.approveFromIsland).isEmpty
    }
    let settings: AppSettings
    var prefs: Preferences { settings.prefs }
    var onOpenSettings: (() -> Void)?
    var lastError: String?
    var eventLog: [String] = []
    /// The Live Activity that is the island.
    let island = ActivityHost()
    var onShowWindow: (() -> Void)?

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

    func dismiss(_ id: String) { store.markSeen(id); reconcile() }
    func dismissAllReviewed() { store.markAllSeen(); reconcile() }

    private let hub = TranscriptHub()
    private var broker = PermissionBroker()
    private var prices = PriceTable.load(from: Paths.pricingURL)
    private var server: NotchServer?
    private var timer: Timer?
    private var beatTimer: Timer?

    // MARK: lifecycle

    func start(demo: Bool) {
        settings.onChange = { [weak self] old, new in
            guard let self else { return }
            // The approval mode lives in settings.json, so changing it means rewriting the hook entry.
            if old.approveFromIsland != new.approveFromIsland, self.hooksInstalled { self.installHooks() }
            self.reconcile()
        }
        beatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.island.beat()
                self?.autoPage()
            }
        }
        if demo {
            runDemo()
            // No hook events arrive in the demo, so only the heartbeat keeps the island from reading as stale (dimmed).
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.island.heartbeat() }
            }
            return
        }
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
        Task { await refreshUsage() }
    }

    private func refreshUsage() async {
        let (u, b) = await usageHub.refresh()
        usage = u
        if b != billing { billing = b }
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
            store.windowCache.record(size: Int(n), session: sid)
            store.windowCache.save()
        }
    }

    // MARK: events

    func ingest(_ env: HookEnvelope, reply: ReplyHandle?) {
        log(env)
        let sid = env.payload.sessionId ?? ""
        let name = env.payload.hookEventName ?? ""
        activityTrace("event \(name) \(sid.prefix(8)) reply=\(reply != nil)")
        if name == "StatusLine" { handleStatusLine(env.payload); return }
        // Release a held hook only when this event really settles its request (see PermissionBroker).
        broker.handle(event: name, payload: env.payload, pending: store.sessions[sid]?.pending)
        if let reply {
            broker.register(reply, for: sid)
            reply.onClose = { [weak self, weak reply] in
                Task { @MainActor in
                    guard let self, let reply else { return }
                    activityTrace("peerClosed \(sid.prefix(8))")
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
                    kind: kind, session: s, sound: prefs.soundEnabled && !island.isLive, banner: prefs.systemNotifications,
                    details: prefs.bannerDetails)
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
        // Prefer the exact conversation in Claude Desktop (this also activates the app).
        if let link = DesktopSessionLink.url(forCLISession: s.id) {
            NSWorkspace.shared.open(link)
            reconcile()
            return
        }
        let bundle: String? =
            if s.entrypoint?.contains("desktop") == true { "com.anthropic.claudefordesktop" } else {
                [
                    "iTerm.app": "com.googlecode.iterm2", "Apple_Terminal": "com.apple.Terminal",
                    "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm",
                    "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable",
                ][s.termProgram ?? ""]
            }
        // NSRunningApplication.activate() is ignored when this (accessory) app isn't frontmost, which is the case when
        // the tap comes from the Live Activity. Launch Services always brings the target forward.
        if let b = bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        reconcile()
    }

    func tick() async {
        tickCount += 1
        if tickCount % 15 == 0 { await refreshUsage() }  // every ~30 s
        if tickCount % 150 == 0 { store.catalog = ModelCatalog.load() }  // every ~5 min: Claude refreshes its model catalog
        if tickCount % 30 == 0 { island.heartbeat() }  // every ~60 s: keeps the activity from reading as stale
        let before = Set(store.sessions.keys)
        // Pruning can also finish a session whose subagents went silent; deliver that "finished" notification.
        let effects = store.prune(idleTTL: prefs.sessionRetention.seconds)
        for case .notify(let id, let kind) in effects {
            if let s = store.sessions[id], prefs.shouldNotify(kind) {
                Notifier.post(
                    kind: kind, session: s, sound: prefs.soundEnabled && !island.isLive, banner: prefs.systemNotifications,
                    details: prefs.bannerDetails)
            }
        }
        for gone in before.subtracting(store.sessions.keys) { await hub.forget(gone) }  // don't leak tailers of pruned sessions
        for s in store.active {
            if let p = s.transcriptPath { await refreshTranscript(id: s.id, path: p) }
        }
        // Looking at a finished session in Claude Desktop counts as reviewing it.
        store.markViewed { DesktopSessionLink.lastFocused(forCLISession: $0) }
        reconcile()
    }

    private func refreshTranscript(id: String, path: String) async {
        let snap = await hub.poll(id: id, path: path)
        store.applyTranscript(snap, to: id, prices: prices)
    }

    // MARK: Live Activity

    /// (Re)starts the island. Starting needs the foreground, so bring the app forward first.
    func showIsland() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Task { @MainActor in
            await island.resetExisting()  // always a fresh activity: the old one may be "active" but not on screen
            try? await Task.sleep(for: .milliseconds(400))
            reconcile()
            if island.isLive { try? await Task.sleep(for: .seconds(2)); NSApp.setActivationPolicy(.accessory) } else { onShowWindow?() }
        }
    }

    private var seenAttention: Set<String> = []
    /// The island's session page; the reducer wraps it. Reset to the first (most urgent) page when something new
    /// needs the user.
    private var islandPage = 0
    /// Pages turn by themselves every `pageInterval`. The island can't report hover, so any tap on it (and anything new
    /// needing the user) holds the current page for `pageHold` instead.
    private var lastPageTurn = Date()
    private var pageHoldUntil = Date.distantPast
    private static let pageInterval: TimeInterval = 6
    private static let pageHold: TimeInterval = 20

    private func holdPage() {
        pageHoldUntil = Date().addingTimeInterval(Self.pageHold)
        lastPageTurn = Date()
    }

    /// Called every second: turns to the next page when there is more than one and nobody is interacting.
    private func autoPage() {
        let now = Date()
        guard let st = island.current, st.pages > 1, now >= pageHoldUntil,
            now.timeIntervalSince(lastPageTurn) >= Self.pageInterval
        else { return }
        lastPageTurn = now
        islandPage += 1
        reconcile()
        activityTrace("auto page \(islandPage + 1)/\(st.pages)")
    }

    /// Pushes the current state to the island. Something *new* that needs the user (a new request, a newly finished
    /// turn) also raises an alert so the island expands by itself, as the old auto-open did.
    func reconcile() {
        if snapshotOnly { return }
        var state = NotchActivityState.make(
            sessions: store.active, quota: quotaNow, maxRows: prefs.islandSize.maxRows, page: islandPage)
        state.scale = prefs.islandSize.scale
        func key(_ s: AgentSession) -> String { "\(s.id)|\(s.status.rawValue)|\(s.pending?.id.uuidString ?? "")" }
        let waiting = store.active.filter { $0.status.needsAttention || $0.needsReview }
        let keys = Set(waiting.map(key))
        var alert: (title: String, body: String, sound: Bool)?
        if let lead = waiting.first(where: { !seenAttention.contains(key($0)) }), lead.status.needsAttention || prefs.autoExpandOnEvents {
            alert = (lead.projectName, lead.pending?.summary ?? lead.activity, prefs.soundEnabled)
        }
        seenAttention = keys
        if alert != nil { holdPage() }
        if alert != nil, state.page != 0 {
            islandPage = 0
            state = NotchActivityState.make(
                sessions: store.active, quota: quotaNow, maxRows: prefs.islandSize.maxRows, page: 0)
            state.scale = prefs.islandSize.scale
        } else {
            islandPage = state.page  // keep it in range as sessions come and go
        }
        if !island.isLive, NSApp.isActive { island.ensureStarted(with: state) }  // starting needs the foreground
        if alert != nil { activityTrace("alert \(state.headline)") }
        island.push(state, alert: alert)
    }

    /// Answers an Allow/Deny/Open/Done tap from the island. A tap for a request that is no longer the live one is ignored.
    func handleIntent(_ action: IntentBridge.Action, sessionId: String, requestId: String) {
        holdPage()  // the user is using the island: stop turning pages under them
        switch action {
        case .nextPage, .previousPage:
            activityTrace("intent \(action)")
            islandPage += action == .nextPage ? 1 : -1
            reconcile()
            return
        case .refreshUsage:
            refreshUsageNow()
            return
        default: break
        }
        guard let s = store.sessions[sessionId] else { return }
        activityTrace("intent \(action) answerable=\(s.isAnswerable(requestId: requestId))")
        switch action {
        case .allow where s.isAnswerable(requestId: requestId): answer(sessionId, .allow)
        case .deny where s.isAnswerable(requestId: requestId): answer(sessionId, .deny)
        case .allow, .deny: break
        case .open:
            if s.isAnswerable(requestId: requestId), s.pending?.isQuestion == true { answerQuestion(s) } else { open(s) }
        case .nextPage, .previousPage, .refreshUsage: break
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

    /// Set by `--snapshot`: the demo data is loaded but no Live Activity is started or updated.
    var snapshotOnly = false

    /// The demo sessions, for rendering snapshots of the island views.
    func loadDemoForSnapshot() -> [AgentSession] {
        snapshotOnly = true
        runDemo()
        return store.active
    }

    private func runDemo() {
        func e(
            _ n: String, _ sid: String, reply: Bool = false, ago: TimeInterval = 0, _ cfg: (inout HookPayload) -> Void = { _ in }
        ) -> HookEnvelope {
            var p = HookPayload(sessionId: sid, cwd: "/Users/you/code/\(sid)", hookEventName: n); cfg(&p)
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
        reconcile()
    }
}
