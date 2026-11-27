import NotchbotCore
import SwiftUI

let coral = Color(red: 0.85, green: 0.47, blue: 0.34)
let amber = Color(red: 1.0, green: 0.72, blue: 0.2)

extension AgentStatus {
    var color: Color {
        switch self {
        case .working, .compacting: coral
        case .needsPermission, .needsInput: amber
        case .failed: .red
        case .done: .green
        case .ended: .gray
        }
    }
}

enum Metrics {
    static let islandRadius: CGFloat = 32
    static let inset: CGFloat = 12
    /// Concentric corners: inner radius = outer radius − inset, the rule the system islands follow.
    static var cardRadius: CGFloat { islandRadius - inset }
}

// MARK: - Shared pieces

struct ChipButton: View {
    let title: String
    var tint: Color
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(filled ? tint.opacity(0.85) : tint.opacity(0.18), in: Capsule())
                .foregroundStyle(filled ? Color.black : tint)
        }.buttonStyle(.plain)
    }
}

struct ContextBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(fraction > 0.85 ? Color.red : fraction > 0.65 ? amber : coral)
                    .frame(width: max(3, g.size.width * fraction))
            }
        }
    }
}

struct SessionList: View {
    let model: AppModel

    /// Rough height used before the first real measurement (and by offscreen snapshots).
    static func estimate(_ sessions: [AgentSession]) -> CGFloat {
        guard !sessions.isEmpty else { return 64 }
        var h: CGFloat = 0
        for s in sessions {
            if s.status == .done && !s.unseen { h += 52; continue }
            var c: CGFloat = 24 + 40 + 18  // padding, header, meta
            if s.lastPrompt != nil { c += 34 }
            if s.status == .working { c += 22 }
            if !s.subagents.isEmpty { c += 22 + 20 * CGFloat(min(s.subagents.count, 4)) }
            if s.pending != nil { c += 100 } else if s.status.needsAttention { c += 44 } else if s.needsReview { c += 84 }
            h += c + 8
        }
        return h + 24 * 3 + 300  // 300 ≈ the usage card (title, three limit rows, refresh, settings link)
    }

    var body: some View {
        let a = model.store.active
        let needs = a.filter { $0.status.needsAttention }
        let review = a.filter { $0.needsReview }
        let working = a.filter { $0.status == .working || $0.status == .compacting }
        let idle = a.filter { $0.status == .done && !$0.unseen }
        VStack(alignment: .leading, spacing: 12) {
            section("Needs you", amber, needs)
            section("Ready to review", .green, review)
            section("Working", coral, working)
            section("Idle", .gray, idle, compact: true)
            if model.prefs.showUsageCard { UsageCard(model: model) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ tint: Color, _ rows: [AgentSession], compact: Bool = false) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    Text("\(rows.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }.padding(.leading, 4)
                ForEach(rows) { s in SessionCard(model: model, session: s, compact: compact).id(s.id) }
            }
        }
    }
}

// MARK: - Usage (plan limits, laid out like Claude Desktop's usage menu)

private let quotaBlue = Color(red: 0.27, green: 0.47, blue: 0.90)

/// Blue normally, amber when running low, red when nearly exhausted (matches Claude Desktop's widget).
func quotaColor(_ fraction: Double) -> Color {
    fraction >= 0.90 ? Color(red: 0.86, green: 0.27, blue: 0.27) : fraction >= 0.75 ? Color(red: 0.96, green: 0.72, blue: 0.26) : quotaBlue
}

/// A small round icon button (refresh, settings, ...), quieter than a text row.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

struct UsageCard: View {
    @Bindable var model: AppModel

    private var updated: Date? { [model.quota?.updatedAt, model.usage.updatedAt].compactMap { $0 }.max() }
    private var showingPercent: Bool { model.prefs.usageDisplay == .percent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("PLAN USAGE LIMITS" + (model.planName.map { " · \($0.uppercased())" } ?? ""))
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.clockwise", help: "Refresh usage") { model.refreshUsageNow() }
                IconButton(symbol: "gearshape", help: "Usage settings") { model.openUsageSettings() }
            }

            if showingPercent { limits } else { tokens }

            HStack {
                UsageModeToggle(model: model)
                Spacer(minLength: 6)
                if let u = updated {
                    TimelineView(.periodic(from: .now, by: 15)) { c in
                        Text("Updated \(Fmt.ago(u, now: c.date))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(Metrics.inset + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Percentage bars, one per window. Re-evaluated every 30 s so a window that resets drops back to 0%.
    @ViewBuilder private var limits: some View {
        if model.quota != nil {
            TimelineView(.periodic(from: .now, by: 30)) { c in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.quota?.refreshed(now: c.date).windows ?? []) { QuotaRow(window: $0) }
                }
            }
        } else if model.planName == nil {
            Text("Plan limits apply to Claude Pro and Max subscriptions.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    model.statusLineInstalled
                        ? "No limits reported yet. They come from Claude Code in a terminal: run `claude` once and they'll appear here and be remembered. The desktop app's Code tab doesn't report them."
                        : "Percentages come from Claude Code's status line."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !model.statusLineInstalled {
                        ChipButton(title: "Enable quota gauges", tint: coral, filled: true) { model.installStatusLine() }
                    }
                    ChipButton(title: "Show tokens instead", tint: .gray) { model.settings.prefs.usageDisplay = .tokens }
                }
            }
        }
    }

    private var tokens: some View {
        HStack(spacing: 0) {
            stat("Last 5h", model.usage.fiveHour.work)
            stat("Today", model.usage.today.work)
            stat("7 days", model.usage.week.work)
        }
    }

    private func stat(_ label: String, _ tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.tokens(tokens)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("\(label) · tokens").font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two-state pill to flip the usage card between plan-limit percentages and raw token counts.
struct UsageModeToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            segment("Limits", .percent)
            segment("Tokens", .tokens)
        }
        .padding(2)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func segment(_ title: String, _ mode: Preferences.UsageDisplay) -> some View {
        let on = model.prefs.usageDisplay == mode
        return Button {
            model.settings.prefs.usageDisplay = mode
        } label: {
            Text(title).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(on ? Color.white.opacity(0.18) : .clear, in: Capsule())
                .foregroundStyle(on ? Color.white : Color.secondary)
        }.buttonStyle(.plain)
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(
                    "\(Int(window.usedPercent.rounded()))%"
                        + (window.resetsAt.map { " · Resets \(Fmt.until($0, fiveHour: window.id == "five_hour"))" } ?? "")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(quotaColor(window.fraction)).frame(width: max(8, g.size.width * window.fraction))
                }
            }.frame(height: 8)
        }
    }
}

// MARK: - Session card

struct SessionCard: View {
    let model: AppModel
    let session: AgentSession
    let compact: Bool
    private var s: AgentSession { session }

    private var border: Color {
        return s.status.needsAttention ? amber.opacity(0.55) : s.needsReview ? Color.green.opacity(0.4) : Color.white.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !compact {
                if model.prefs.showPrompt, let prompt = s.lastPrompt { LabeledText(label: "You", text: prompt, lines: 2) }
                if s.status == .working || s.status == .compacting { activityLine }
                if model.prefs.showSubagents, !s.subagents.isEmpty { SubagentList(model: model, session: s) }
                request
                if model.prefs.showContextMeter { meta }
            }
        }
        .padding(compact ? 10 : Metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color.white.opacity(s.status.needsAttention ? 0.10 : 0.06))
        )
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onTapGesture { model.open(s) }  // empty space on a card opens Claude; buttons handle their own taps
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(s.status.color).frame(width: 8, height: 8)
                .shadow(color: s.status.color.opacity(s.status.needsAttention ? 0.9 : 0), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    // The name already is the project when there is no title; don't repeat it.
                    Text(([s.title == nil ? nil : s.projectName, s.displayBranch].compactMap { $0 }).joined(separator: " · "))
                    Text("·").foregroundStyle(.tertiary)
                    if let w = s.workingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { c in Text(Fmt.duration(c.date.timeIntervalSince(w))).monospacedDigit()
                        }
                    } else {
                        Text(
                            s.lastTurnDuration.map(Fmt.duration) ?? (s.pending?.isQuestion == true ? "Has a question" : Fmt.label(s.status))
                        )
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if model.showCost {
                    Text(Fmt.cost(s.costUSD)).font(.system(size: 11.5, weight: .semibold))
                        .help("Estimated cost of this session at API prices.")
                    if !compact {
                        Text("\(Fmt.tokens(s.usage.work)) tok").font(.system(size: 10.5)).foregroundStyle(.secondary).help(tokenHelp)
                    }
                } else {
                    Text("\(Fmt.tokens(s.usage.work)) tok").font(.system(size: 11.5, weight: .semibold)).help(tokenHelp)
                }
                // This session's own subagents (the header carries the global count).
                if !compact, let summary = s.subagentSummary {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .semibold))
                        Text(summary).font(.system(size: 10))
                    }
                    .foregroundStyle(s.runningSubagents > 0 ? coral.opacity(0.95) : Color.green.opacity(0.85))
                    .help("Subagents this session started: \(summary).")
                }
            }.monospacedDigit()
        }
    }

    private var tokenHelp: String {
        let u = s.usage
        return "Tokens this session processed: \(Fmt.tokens(u.input)) input, \(Fmt.tokens(u.output)) output, "
            + "\(Fmt.tokens(u.cacheWrite)) written to cache (cache reads not counted)."
    }

    private var activityLine: some View {
        HStack(spacing: 6) {
            RobotView().frame(width: 16, height: 16)
            Text(s.activity).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(coral.opacity(0.95)).lineLimit(1)
        }
    }

    @ViewBuilder private var request: some View {
        if let p = s.pending {
            PermissionBar(model: model, session: s, pending: p)
        } else if s.status == .needsInput || s.status == .failed {
            VStack(alignment: .leading, spacing: 8) {
                LabeledText(
                    label: s.status == .failed ? "Error" : "Claude", text: s.attentionMessage ?? Fmt.label(s.status), lines: 3, tint: amber)
                HStack(spacing: 8) {
                    ChipButton(title: "Open", tint: amber, filled: true) { model.open(s) }
                    ChipButton(title: "Dismiss", tint: .gray) { model.dismiss(s.id) }
                }
            }
        } else if s.needsReview {
            VStack(alignment: .leading, spacing: 8) {
                if let m = s.lastMessage { LabeledText(label: "Claude", text: m, lines: 4, bright: true) }
                HStack(spacing: 8) {
                    ChipButton(title: "Open", tint: .green, filled: true) { model.open(s) }
                    ChipButton(title: "Mark reviewed", tint: .gray) { model.dismiss(s.id) }
                }
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            if let f = s.contextFraction, let w = s.contextWindow {
                HStack(spacing: 8) {
                    ContextBar(fraction: f).frame(width: 64, height: 4)
                    Text("\(Int(f * 100))% context")
                }
                .help(
                    "Context window used: \(Fmt.tokens(s.contextTokens)) of \(Fmt.tokens(w)) tokens. "
                        + "Claude Code compacts the conversation as this fills up.")
            }
            if s.linesAdded + s.linesRemoved > 0 {
                HStack(spacing: 4) {
                    Text("+\(s.linesAdded)").foregroundStyle(.green.opacity(0.9))
                    Text("−\(s.linesRemoved)").foregroundStyle(.red.opacity(0.9))
                }
                .help("Lines added and removed by this session's edits: \(s.linesAdded) added, \(s.linesRemoved) removed.")
            }
            Spacer(minLength: 0)
            if s.toolCalls > 0 {
                Text("\(s.toolCalls) tool calls").help("Tools this session has run (Bash, Edit, Read, …) since it started.")
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct LabeledText: View {
    /// Claude's replies are markdown: render bold/code/links instead of showing the raw `**`.
    static func rendered(_ raw: String) -> AttributedString {
        let flat = Fmt.inlineMarkdown(raw)
        return (try? AttributedString(markdown: flat, options: .init(interpretedSyntax: .inlineOnly))) ?? AttributedString(flat)
    }

    let label: String
    let text: String
    var lines = 2
    var tint: Color = .secondary
    var bright = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(tint == .secondary ? Color.white.opacity(0.35) : tint).frame(width: 50, alignment: .leading)
            Text(Self.rendered(text))
                .font(.system(size: 12)).foregroundStyle(bright ? Color.white.opacity(0.92) : Color.secondary)
                .lineLimit(lines).multilineTextAlignment(.leading)
        }
    }
}

/// The session's subagents as a small tree: running ones first, with what each is doing right now.
/// Collapsed it shows the three most relevant; tap the header to explore all of them with their details.
struct SubagentList: View {
    let model: AppModel
    let session: AgentSession
    private var expanded: Bool { model.expandedSubagents.contains(session.id) }

    var body: some View {
        let subs = session.rankedSubagents
        let shown = expanded ? subs : Array(subs.prefix(3))
        VStack(alignment: .leading, spacing: 5) {
            Button {
                model.toggleSubagents(session.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 7.5, weight: .bold))
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text("SUBAGENTS").font(.system(size: 9, weight: .bold)).tracking(0.5)
                    Text(session.runningSubagents > 0 ? "\(session.runningSubagents) running" : "all done").font(.system(size: 9.5))
                    Spacer(minLength: 4)
                    if subs.count > 3 {
                        Text(expanded ? "Show less" : "Show all \(subs.count)").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, sub in
                SubagentRow(sub: sub, isLast: i == shown.count - 1, detailed: expanded)
            }
        }
        .padding(.leading, 4)
    }
}

struct SubagentRow: View {
    let sub: Subagent
    let isLast: Bool
    let detailed: Bool

    private var detail: String {
        if sub.status == .running { return sub.currentDetail ?? sub.description ?? "working…" }
        return sub.lastMessage.map(Fmt.plainText) ?? sub.description ?? "done"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Tree branch glyph: ├ for siblings, └ for the last child.
            Text(isLast ? "└" : "├").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.25)).frame(
                width: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Group {
                        if sub.status == .running {
                            Circle().fill(coral)
                        } else {
                            Circle().strokeBorder(Color.green.opacity(0.9), lineWidth: 1.5)
                        }
                    }.frame(width: 6, height: 6)
                    Text(sub.type).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    if detailed {
                        if let d = sub.description {
                            Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // How long it has been working (live), or how long it took.
                    if sub.status == .running {
                        HStack(spacing: 3) {
                            Image(systemName: "timer").font(.system(size: 8.5))
                            TimelineView(.periodic(from: .now, by: 1)) { c in Text(Fmt.duration(c.date.timeIntervalSince(sub.startedAt))) }
                        }.foregroundStyle(coral.opacity(0.95))
                    } else if let e = sub.endedAt {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                            Text(Fmt.duration(e.timeIntervalSince(sub.startedAt)))
                        }.foregroundStyle(Color.green.opacity(0.85))
                    }
                }
                .font(.system(size: 10.5)).monospacedDigit()
                if detailed {
                    Text(detail)
                        .font(.system(size: 11, design: sub.status == .running ? .monospaced : .default))
                        .foregroundStyle(sub.status == .running ? coral.opacity(0.95) : Color.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text("\(sub.toolCalls) tool call\(sub.toolCalls == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// The choices of a question as read-only pills that wrap onto as many lines as they need.
struct FlowChips: View {
    let items: [String]
    var more = 0
    var multi = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { Text($0).font(.system(size: 11)).lineLimit(1).chip() }
                }
            }
            if more > 0 { Text("+\(more) more").font(.system(size: 10.5)).foregroundStyle(.secondary) }
            if multi { Text("Pick any").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
    /// Greedy packing by approximate text width so pills wrap without a custom Layout.
    private var rows: [[String]] {
        var out: [[String]] = [[]]
        var width = 0
        for it in items {
            let w = it.count * 7 + 22
            if width + w > 250, !out[out.count - 1].isEmpty { out.append([]); width = 0 }
            out[out.count - 1].append(it)
            width += w + 5
        }
        return out
    }
}

private extension View {
    func chip() -> some View {
        padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

struct PermissionBar: View {
    let model: AppModel
    let session: AgentSession
    let pending: PendingPermission

    var body: some View {
        if pending.isQuestion { questionBody } else { permissionBody }
    }

    /// Claude asking the user something: show the question and its choices, not a tool name.
    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(pending.question?.header.map { "Claude asks · \($0)" } ?? "Claude has a question", systemImage: "bubble.left.fill")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(amber)
            Text(pending.summary).font(.system(size: 13, weight: .medium)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            if let opts = pending.question?.options, !opts.isEmpty {
                // Read-only: the answer is given in Claude itself.
                FlowChips(items: Array(opts.prefix(6)), more: max(0, opts.count - 6), multi: pending.question?.multiSelect == true)
            }
            if let total = pending.question?.total, total > 1 {
                Text("+\(total - 1) more question\(total == 2 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ChipButton(title: "Answer in Claude", tint: amber, filled: true) {
                    pending.canAnswer ? model.answerQuestion(session) : model.open(session)
                }
                if pending.canAnswer { ChipButton(title: "Not now", tint: .gray) { model.answer(session.id, .deny) } }
            }
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = pending.agentType {
                Text("Subagent \(a) wants to run").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(amber)
            }
            Text(pending.summary).font(.system(size: 11.5, design: .monospaced)).lineLimit(3)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                if pending.canAnswer {
                    ChipButton(title: "Allow", tint: .green, filled: true) { model.answer(session.id, .allow) }
                    ChipButton(title: "Deny", tint: .red) { model.answer(session.id, .deny) }
                } else {
                    ChipButton(title: "Open", tint: amber, filled: true) { model.open(session) }
                    Text("Answer in your terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FooterView: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if model.hooksInstalled && model.hooksOutdated {
                // Installed by an older version: missing events (e.g. SubagentStart) mean subagents are noticed late.
                ChipButton(title: "Update hooks", tint: amber, filled: true) { model.installHooks() }
            } else if !model.hooksInstalled {
                ChipButton(title: "Install hooks", tint: coral, filled: true) { model.installHooks() }
            }
            // When hooks are installed and current there is nothing to say: no "all good" status line.
            if let e = model.lastError { Text(e).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1) }
            Spacer()
            IslandMenu(model: model)
        }
    }
}

struct IslandMenu: View {
    let model: AppModel
    var body: some View {
        Menu {
            Button("Settings…") { model.onOpenSettings?() }.keyboardShortcut(",")
            Button("Mark all reviewed") { model.dismissAllReviewed() }
            Divider()
            Button("Quit NotchBot") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
    }
}
