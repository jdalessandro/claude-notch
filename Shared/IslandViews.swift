import AppIntents
import ClaudeNotchCore
import SwiftUI

// The island's views. They live in Shared so the widget draws them and the app can render the same views to PNG
// (`ClaudeNotch --snapshot <dir>`) for docs and for checking layout without the real island.
// Styled after the system media island: big artwork, a bold title over a grey subtitle, a waveform on the right,
// no outlines, generous continuous corners.

enum Island {
    static let coral = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.0)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let surface = Color.white.opacity(0.08)
    static let panelRadius: CGFloat = 22

    static func quota(_ f: Double) -> Color { f >= 0.9 ? red : f >= 0.75 ? amber : blue }
    static func context(_ f: Double) -> Color { f > 0.85 ? red : f > 0.65 ? amber : coral }
}

extension NotchActivityState.Phase {
    /// The waveform's colour: coral while agents work, amber when you are needed.
    var waveTint: Color { self == .needsYou ? Island.amber : Island.coral }
}

extension NotchActivityState.Kind {
    var tint: Color {
        switch self {
        case .approval, .question, .input: Island.amber
        case .failed: Island.red
        case .review: Island.green
        case .working: Island.coral
        case .idle: Color.white.opacity(0.3)
        }
    }
    var needsYou: Bool { self == .approval || self == .question || self == .input || self == .failed }
}

extension NotchActivityState.Row {
    /// The status badge's words.
    var status: String {
        switch kind {
        case .approval: fromSubagent ? "Subagent asks" : "Needs approval"
        case .question: "Question"
        case .input: "Waiting for you"
        case .failed: "Failed"
        case .review: "Ready to review"
        case .working: "Working"
        case .idle: "Idle"
        }
    }
}

// MARK: - Artwork

/// The radial burst drawn on the artwork: rounded rays of alternating length around a common centre.
struct Burst: Shape {
    var rays = 12
    func path(in r: CGRect) -> Path {
        let lengths: [CGFloat] = [1.0, 0.74, 0.92, 0.70, 0.98, 0.78, 0.90, 0.72, 1.0, 0.76, 0.94, 0.70]
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        let w = radius * 0.2
        var p = Path()
        for i in 0..<rays {
            let len = radius * lengths[i % lengths.count]
            let ray = CGRect(x: -w / 2, y: -len, width: w, height: len - radius * 0.08)
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(i) / CGFloat(rays) * 2 * .pi)
            p.addPath(Path(roundedRect: ray, cornerRadius: w / 2).applying(t))
        }
        p.addEllipse(in: CGRect(x: c.x - w * 0.9, y: c.y - w * 0.9, width: w * 1.8, height: w * 1.8))
        return p
    }
}

/// Stands in for album art: the coral burst on its own, no tile. It does not change colour with state;
/// the waveform and an amber badge carry that.
struct Artwork: View {
    var size: CGFloat
    var badge = 0
    var body: some View {
        Burst()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.60, blue: 0.45), Island.coral],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: size * 0.88, height: size * 0.88)
            .frame(width: size, height: size)
            // Kept inside the frame: the compact region clips anything that sticks out.
            .overlay(alignment: .bottomTrailing) {
                if badge > 0 {
                    Text("\(badge)").font(.system(size: max(8, size * 0.36), weight: .bold, design: .rounded))
                        .foregroundStyle(.black).monospacedDigit()
                        .padding(.horizontal, size * 0.08).frame(minWidth: size * 0.5, minHeight: size * 0.5)
                        .background(Capsule().fill(Island.amber))
                        .overlay(Capsule().strokeBorder(.black, lineWidth: max(1, size * 0.07)))
                }
            }
    }
}

// MARK: - Waveform

/// One bar per running agent: full-width bars for working sessions, slightly thinner ones for their subagents.
/// Rests as dots when nothing runs.
///
/// The system draws a Live Activity from a snapshot of this view, so repeating animations (symbol effects,
/// `TimelineView`) never run. Instead the app sends a `pulse` beat about once a second while agents run; each beat
/// picks new bar heights and the island animates the change, which reads as a moving waveform.
struct AgentWave: View {
    let agents: Int
    let subagents: Int
    let tint: Color
    var pulse = 0
    var height: CGFloat = 18
    static let maxBars = 7

    /// Bar `i`'s height (0.3...1) at beat `pulse`: deterministic, different per bar, never two beats alike.
    static func level(_ i: Int, _ pulse: Int) -> CGFloat {
        let t = Double(pulse)
        let v = sin(t * 1.9 + Double(i) * 2.4) * 0.5 + sin(t * 0.7 + Double(i) * 1.3) * 0.5
        return CGFloat(0.3 + 0.7 * abs(v))
    }

    var body: some View {
        let main = min(agents, Self.maxBars)
        let subs = min(subagents, Self.maxBars - main)
        if main + subs == 0 {
            HStack(spacing: height * 0.16) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.4)).frame(width: height * 0.15, height: height * 0.15)
                }
            }
            .frame(height: height)
        } else {
            HStack(alignment: .center, spacing: height * 0.14) {
                ForEach(0..<(main + subs), id: \.self) { i in
                    let isSub = i >= main
                    Capsule().fill(tint)
                        .frame(
                            width: height * (isSub ? 0.12 : 0.17),
                            height: height * Self.level(i, pulse) * (isSub ? 0.75 : 1))
                }
            }
            .frame(height: height)
            .animation(.easeInOut(duration: 0.9), value: pulse)
        }
    }
}

extension AgentWave {
    /// Bars for the working sessions and their subagents. When nothing runs but something waits on you, one amber bar
    /// per waiting session keeps the island visibly asking.
    init(state: NotchActivityState, height: CGFloat = 18) {
        let agents = state.working > 0 ? state.working : (state.phase == .needsYou ? state.needsYou : 0)
        self.init(
            agents: agents, subagents: state.subagentsRunning, tint: state.phase.waveTint, pulse: state.pulse, height: height)
    }
}

// MARK: - Buttons

/// A pill button label. `filled` uses the tint as the fill with white text; otherwise a quiet translucent fill.
struct Pill: View {
    let title: String
    var tint: Color = .white
    var filled = false
    var height: CGFloat = 32
    var stretch = true
    var body: some View {
        Text(title).font(.system(size: height * 0.42, weight: .semibold)).lineLimit(1)
            .foregroundStyle(filled ? Color.white : tint == .white ? Color.white : tint)
            .padding(.horizontal, height * 0.45)
            .frame(maxWidth: stretch ? .infinity : nil, minHeight: height, maxHeight: height)
            .background(Capsule().fill(filled ? tint : Color.white.opacity(0.14)))
            .contentShape(Capsule())
    }
}

// MARK: - Badges

/// A small capsule label. `tinted` uses the colour for text on a faint wash of it; neutral is grey on grey.
struct Badge<Label: View>: View {
    var tint: Color? = nil
    var icon: String? = nil
    @ViewBuilder var label: Label
    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            label
        }
        .font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1)
        .foregroundStyle(tint ?? Color.white.opacity(0.7))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.1 : 0.18)))
        .fixedSize()
    }
}

extension Badge where Label == Text {
    init(_ text: String, tint: Color? = nil, icon: String? = nil) {
        self.init(tint: tint, icon: icon) { Text(text) }
    }
}

// MARK: - The featured request

/// The most urgent request: who asks and what kind, the question with its choices or the command, and the answer
/// buttons. Kept tight: the expanded island has a fixed maximum height and clips anything taller.
struct PromptPanel: View {
    let p: NotchActivityState.Prompt
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(p.session).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 6)
                if p.isQuestion {
                    if let h = p.header { Badge(h) }
                    Badge("Question", tint: Island.amber, icon: "questionmark.bubble.fill")
                } else {
                    Badge(p.tool, icon: "terminal.fill")
                    Badge(p.subagent == nil ? "Needs approval" : "Subagent asks", tint: Island.amber, icon: "lock.fill")
                }
            }
            if p.isQuestion { question } else { permission }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Island.panelRadius, style: .continuous).fill(Island.amber.opacity(0.10)))
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(p.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !p.options.isEmpty {
                // Read-only: the answer is given in Claude itself.
                HStack(spacing: 5) {
                    ForEach(p.options, id: \.self) { o in
                        Text(o).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    if p.moreOptions > 0 { Badge("+\(p.moreOptions)") }
                    Spacer(minLength: 0)
                    if p.multiSelect { Badge("Choose any") }
                    if p.moreQuestions > 0 { Badge("+\(p.moreQuestions) more") }
                }
            }
        }
    }

    private var permission: some View {
        Text(p.text).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
            .lineLimit(2).padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.55)))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if !p.canAnswer {
                Button(intent: OpenSessionIntent(sessionId: p.sessionId)) {
                    Pill(title: "Open", tint: Island.coral, filled: true, height: 30)
                }
                Text(p.isQuestion ? "Answer it in Claude" : "Answer it in your terminal").font(.system(size: 12))
                    .foregroundStyle(Island.secondary).frame(maxWidth: .infinity)
            } else if p.isQuestion {
                Button(intent: DenyIntent(sessionId: p.sessionId, requestId: p.requestId)) { Pill(title: "Not now", height: 30) }
                Button(intent: OpenSessionIntent(sessionId: p.sessionId, requestId: p.requestId)) {
                    Pill(title: "Answer in Claude", tint: Island.coral, filled: true, height: 30)
                }
            } else {
                Button(intent: DenyIntent(sessionId: p.sessionId, requestId: p.requestId)) {
                    Pill(title: "Deny", tint: Island.red, height: 30)
                }
                Button(intent: AllowIntent(sessionId: p.sessionId, requestId: p.requestId)) {
                    Pill(title: "Allow", tint: Island.green, filled: true, height: 30)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session cards

/// One session in two lines: name, branch and status; then what it is doing, with its actions or stats beside it.
struct SessionRow: View {
    let row: NotchActivityState.Row
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .layoutPriority(1)
                if let b = row.branch { Badge(b, icon: "arrow.triangle.branch") }
                Spacer(minLength: 6)
                status
            }
            HStack(spacing: 5) {
                Text(row.detail)
                    .font(.system(size: 12.5, design: row.kind == .approval ? .monospaced : .default))
                    .foregroundStyle(row.kind.needsYou ? Color.white.opacity(0.85) : Island.secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(row.kind.needsYou ? Island.amber.opacity(0.10) : Island.surface))
    }

    @ViewBuilder private var status: some View {
        if row.kind == .working, let since = row.since {
            Badge(tint: Island.coral) {
                Text(since, style: .timer).multilineTextAlignment(.center).frame(width: 36)
            }
        } else {
            Badge(row.status, tint: row.kind == .idle ? nil : row.kind.tint)
        }
    }

    /// Actions for a session waiting on you; otherwise its stats as badges.
    @ViewBuilder private var trailing: some View {
        HStack(spacing: 5) {
            switch row.kind {
            case .approval:
                if let r = row.requestId {
                    Button(intent: DenyIntent(sessionId: row.id, requestId: r)) {
                        Pill(title: "Deny", tint: Island.red, height: 24, stretch: false)
                    }
                    Button(intent: AllowIntent(sessionId: row.id, requestId: r)) {
                        Pill(title: "Allow", tint: Island.green, filled: true, height: 24, stretch: false)
                    }
                } else {
                    openButton
                }
            case .question:
                Button(intent: OpenSessionIntent(sessionId: row.id, requestId: row.requestId ?? "")) {
                    Pill(title: "Answer", tint: Island.coral, filled: true, height: 24, stretch: false)
                }
            case .input, .failed: openButton
            case .review:
                Button(intent: MarkReviewedIntent(sessionId: row.id)) { Pill(title: "Reviewed", height: 24, stretch: false) }
            case .working, .idle:
                if row.subagentTotal > 0 {
                    Badge(
                        "\(row.subagents > 0 ? row.subagents : row.subagentTotal)",
                        tint: row.subagents > 0 ? Island.coral : nil, icon: "point.3.connected.trianglepath.dotted")
                }
                if row.linesAdded + row.linesRemoved > 0 {
                    Badge {
                        Text("+\(row.linesAdded)").foregroundStyle(Island.green)
                            + Text(" −\(row.linesRemoved)").foregroundStyle(Island.red)
                    }
                }
                Badge(
                    "\(Int(row.context * 100))%", tint: row.context > 0.65 ? Island.context(row.context) : nil,
                    icon: "gauge.with.dots.needle.33percent")
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var openButton: some View {
        Button(intent: OpenSessionIntent(sessionId: row.id)) {
            Pill(title: "Open", tint: Island.coral, filled: true, height: 24, stretch: false)
        }
    }
}

// MARK: - Footer

/// One line: the two plan limits as short meters, and the pager when there is more than one page.
struct Footer: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 12) {
            if let f = state.fiveHour { limit("5h", f) }
            if let w = state.weekly { limit("7d", w) }
            Spacer(minLength: 0)
            if state.pages > 1 { Pager(state: state) }
        }
        .padding(.horizontal, 4)
    }

    private func limit(_ label: String, _ f: Double) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Island.secondary)
            Capsule().fill(Color.white.opacity(0.16)).frame(width: 44, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Island.quota(f)).frame(width: max(5, 44 * min(1, f)), height: 5)
                }
            Text("\(Int((f * 100).rounded()))%").foregroundStyle(.white.opacity(0.85)).monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .fixedSize()
    }
}

// MARK: - Pager

/// ‹ dots ›: pages through the sessions, since a Live Activity can't scroll. Each tap asks the app for the next page
/// (wrapping around); the app also turns pages by itself while nobody is tapping.
struct Pager: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 7) {
            Button(intent: PageIntent(forward: false)) { arrow("chevron.left") }
            HStack(spacing: 4) {
                ForEach(0..<min(state.pages, 8), id: \.self) { i in
                    Capsule().fill(Color.white.opacity(i == state.page ? 0.9 : 0.25))
                        .frame(width: i == state.page ? 12 : 5, height: 5)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.page)
            Button(intent: PageIntent(forward: true)) { arrow("chevron.right") }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.12))).contentShape(Circle())
    }
}

// MARK: - Regions

/// The header: how many agents, then badges for what needs you, what is working and how many subagents run.
struct IslandTitle: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 6) {
            Text(state.sessions == 0 ? "No active sessions" : state.sessions == 1 ? "1 agent" : "\(state.sessions) agents")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 6)
            if state.needsYou > 0 { Badge("\(state.needsYou) need\(state.needsYou == 1 ? "s" : "") you", tint: Island.amber) }
            if state.working > 0 { Badge("\(state.working) working", tint: Island.coral) }
            if state.subagentsRunning > 0 {
                Badge("\(state.subagentsRunning)", icon: "point.3.connected.trianglepath.dotted")
            }
        }
    }
}

/// Everything under the header.
struct IslandBody: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = state.prompt { PromptPanel(p: p) }
            ForEach(state.rows) { SessionRow(row: $0) }
            Footer(state: state).padding(.top, 2)
        }
    }
}

/// The expanded content: the idle view when no session is active, otherwise the header and the sessions.
/// Used by the island's bottom region, the banner presentation and snapshots.
struct IslandExpanded: View {
    let state: NotchActivityState
    var body: some View {
        if state.sessions == 0 {
            IslandIdle(state: state)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                IslandTitle(state: state).padding(.horizontal, 4)
                IslandBody(state: state)
            }
        }
    }
}

// MARK: - Idle

/// Nothing running: the logo with a short status, and the plan limits (the one thing worth checking now) with when
/// each resets.
struct IslandIdle: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Artwork(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All quiet").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text("No Claude Code sessions running").font(.system(size: 13)).foregroundStyle(Island.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if state.fiveHour != nil || state.weekly != nil {
                HStack(alignment: .top, spacing: 16) {
                    if let f = state.fiveHour { meter("5-hour limit", f, state.fiveHourReset) }
                    if let w = state.weekly { meter("Weekly limit", w, state.weeklyReset) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Island.surface))
            }
        }
    }

    private func meter(_ label: String, _ f: Double, _ reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Island.secondary)
                Spacer(minLength: 4)
                Text("\(Int((f * 100).rounded()))%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .monospacedDigit()
            }
            Capsule().fill(Color.white.opacity(0.16)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Island.quota(f)).frame(width: max(6, g.size.width * min(1, f)))
                    }
                }
            Group {
                if let reset, reset > .now {
                    Text("Resets in ") + Text(reset, style: .relative)
                } else {
                    Text(f == 0 ? "Not used yet" : "Reset time unknown")
                }
            }
            .font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The compact presentation: the logo on the left of the cutout, the waveform on the right.
struct IslandCompactLeading: View {
    let state: NotchActivityState
    var body: some View { Artwork(size: 17) }
}

struct IslandCompactTrailing: View {
    let state: NotchActivityState
    var body: some View { AgentWave(state: state, height: 15) }
}
