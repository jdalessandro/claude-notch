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

extension NotchActivityState {
    /// Bold first line of the island, like a track title.
    var title: String {
        switch phase {
        case .idle: "Claude Code"
        default: headline
        }
    }
    /// Grey second line, like the artist: how many agents and subagents are running.
    var subtitle: String {
        guard sessions > 0 else { return "No active sessions" }
        var parts: [String] = []
        // "2 working" over "2 agents" says the same thing twice: only count agents when the title doesn't.
        if !(phase == .working && working == sessions) { parts.append(sessions == 1 ? "1 agent" : "\(sessions) agents") }
        if phase == .needsYou, working > 0 { parts.append("\(working) working") }
        if subagentsRunning > 0 { parts.append(subagentsRunning == 1 ? "1 subagent" : "\(subagentsRunning) subagents") }
        return parts.isEmpty ? "All agents busy" : parts.joined(separator: " · ")
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

/// One bar per running agent: full bars for sessions that are working, thinner dimmer bars for their subagents.
/// Each bar breathes at its own speed so the group moves like a waveform. Rests as dots when nothing runs.
struct AgentWave: View {
    let agents: Int
    let subagents: Int
    let tint: Color
    var height: CGFloat = 18
    static let maxBars = 7

    private static let heights: [CGFloat] = [0.55, 0.95, 0.7, 1.0, 0.6, 0.85, 0.5]
    private static let speeds: [Double] = [1.0, 1.45, 0.8, 1.25, 0.95, 1.6, 1.1]

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
                    Image(systemName: "capsule.portrait.fill").resizable()
                        .frame(width: height * (isSub ? 0.12 : 0.17), height: height * Self.heights[i] * (isSub ? 0.75 : 1))
                        .foregroundStyle(tint.opacity(isSub ? 0.55 : 1))
                        .symbolEffect(.breathe.plain.byLayer, options: .repeating.speed(Self.speeds[i]))
                }
            }
            .frame(height: height)
        }
    }
}

extension AgentWave {
    /// Bars for the working sessions and their subagents. When nothing runs but something waits on you, one amber bar
    /// per waiting session keeps the island visibly asking.
    init(state: NotchActivityState, height: CGFloat = 18) {
        let agents = state.working > 0 ? state.working : (state.phase == .needsYou ? state.needsYou : 0)
        self.init(agents: agents, subagents: state.subagentsRunning, tint: state.phase.waveTint, height: height)
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

// MARK: - The featured request

struct PromptPanel: View {
    let p: NotchActivityState.Prompt
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(p.session).font(.system(size: 13, weight: .semibold)).foregroundStyle(Island.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Label(label, systemImage: p.isQuestion ? "bubble.left.fill" : "lock.open.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Island.amber).lineLimit(1)
            }
            if p.isQuestion { question } else { permission }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.panelRadius, style: .continuous).fill(Island.surface))
    }

    private var label: String {
        if p.isQuestion { return p.header ?? "Question" }
        return p.subagent.map { "\(p.tool) · \($0)" } ?? p.tool
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(p.text).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !p.options.isEmpty {
                // Read-only: the answer is given in Claude itself.
                HStack(spacing: 6) {
                    ForEach(p.options, id: \.self) { o in
                        Text(o).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    if p.moreOptions > 0 {
                        Text("+\(p.moreOptions)").font(.system(size: 12, weight: .medium)).foregroundStyle(Island.secondary)
                    }
                }
            }
            let notes = [
                p.multiSelect ? "Pick any" : nil,
                p.moreQuestions > 0 ? "+\(p.moreQuestions) more question\(p.moreQuestions == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            if !notes.isEmpty {
                Text(notes.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Island.tertiary)
            }
        }
    }

    private var permission: some View {
        Text(p.text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
            .lineLimit(3).padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.5)))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if !p.canAnswer {
                Button(intent: OpenSessionIntent(sessionId: p.sessionId)) { Pill(title: "Open", tint: Island.coral, filled: true) }
                Text(p.isQuestion ? "Answer it in Claude" : "Answer it in your terminal").font(.system(size: 12))
                    .foregroundStyle(Island.secondary).frame(maxWidth: .infinity)
            } else if p.isQuestion {
                Button(intent: DenyIntent(sessionId: p.sessionId, requestId: p.requestId)) { Pill(title: "Not now") }
                Button(intent: OpenSessionIntent(sessionId: p.sessionId, requestId: p.requestId)) {
                    Pill(title: "Answer in Claude", tint: Island.coral, filled: true)
                }
            } else {
                Button(intent: DenyIntent(sessionId: p.sessionId, requestId: p.requestId)) { Pill(title: "Deny", tint: Island.red) }
                Button(intent: AllowIntent(sessionId: p.sessionId, requestId: p.requestId)) {
                    Pill(title: "Allow", tint: Island.green, filled: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session rows

/// One session per line: status dot, name over what it is doing, then its action or its timer and stats.
struct SessionRow: View {
    let row: NotchActivityState.Row
    var body: some View {
        HStack(spacing: 11) {
            Circle().fill(row.kind.tint).frame(width: 9, height: 9)
                .shadow(color: row.kind.tint.opacity(row.kind.needsYou ? 0.8 : 0), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(row.detail)
                    .font(.system(size: 13, design: row.kind == .approval ? .monospaced : .default))
                    .foregroundStyle(row.kind.needsYou ? Island.amber : Island.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .approval:
                if let r = row.requestId {
                    Button(intent: DenyIntent(sessionId: row.id, requestId: r)) {
                        Pill(title: "Deny", tint: Island.red, height: 28, stretch: false)
                    }
                    Button(intent: AllowIntent(sessionId: row.id, requestId: r)) {
                        Pill(title: "Allow", tint: Island.green, filled: true, height: 28, stretch: false)
                    }
                } else {
                    openButton
                }
            case .question:
                Button(intent: OpenSessionIntent(sessionId: row.id, requestId: row.requestId ?? "")) {
                    Pill(title: "Answer", tint: Island.coral, filled: true, height: 28, stretch: false)
                }
            case .input, .failed: openButton
            case .review:
                Button(intent: MarkReviewedIntent(sessionId: row.id)) { Pill(title: "Reviewed", height: 28, stretch: false) }
            case .working, .idle: stats
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var openButton: some View {
        Button(intent: OpenSessionIntent(sessionId: row.id)) {
            Pill(title: "Open", tint: Island.coral, filled: true, height: 28, stretch: false)
        }
    }

    /// Elapsed time (tokens when idle) over the subagent count and context used.
    private var stats: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let since = row.since {
                Text(since, style: .timer).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit().multilineTextAlignment(.trailing).frame(width: 56, alignment: .trailing)
            } else {
                Text("\(Fmt.tokens(row.tokens)) tok").font(.system(size: 13, weight: .medium)).foregroundStyle(Island.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 5) {
                if row.subagentTotal > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .bold))
                        Text("\(row.subagents > 0 ? row.subagents : row.subagentTotal)")
                    }
                    .foregroundStyle(row.subagents > 0 ? Island.coral : Island.green)
                }
                Text("\(Int(row.context * 100))% ctx").foregroundStyle(Island.context(row.context).opacity(0.9))
            }
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
    }
}

// MARK: - Footer

/// Plan limits as two slim bars, like the media island's scrubber, and how many sessions are not shown.
struct LimitsFooter: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.more > 0 {
                Text("+\(state.more) more session\(state.more == 1 ? "" : "s")").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Island.tertiary).padding(.horizontal, 4)
            }
            if state.fiveHour != nil || state.weekly != nil {
                HStack(spacing: 14) {
                    if let f = state.fiveHour { limit("5h", f) }
                    if let w = state.weekly { limit("7d", w) }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func limit(_ label: String, _ f: Double) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Island.secondary)
            Capsule().fill(Color.white.opacity(0.18)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Island.quota(f)).frame(width: max(6, g.size.width * min(1, f)))
                    }
                }
            Text("\(Int((f * 100).rounded()))%").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
    }
}

// MARK: - Regions

/// Title and subtitle (the expanded center region).
struct IslandTitle: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(state.subtitle).font(.system(size: 14)).foregroundStyle(Island.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Everything under the title row (the expanded bottom region).
struct IslandBody: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = state.prompt { PromptPanel(p: p) }
            if !state.rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) { ForEach(state.rows) { SessionRow(row: $0) } }
            }
            LimitsFooter(state: state)
        }
        .padding(.top, 4)
    }
}

/// The whole expanded layout in one view: used for the banner presentation and for snapshots.
struct IslandExpanded: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Artwork(size: 52)
                IslandTitle(state: state)
                AgentWave(state: state, height: 20)
            }
            IslandBody(state: state)
        }
    }
}

/// The compact presentation: artwork on the left of the cutout, waveform on the right.
struct IslandCompactLeading: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 5) {
            Artwork(size: 22)
            if state.needsYou > 0 {
                Text("\(state.needsYou)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Island.amber)
                    .monospacedDigit()
            }
        }
    }
}

struct IslandCompactTrailing: View {
    let state: NotchActivityState
    var body: some View { AgentWave(state: state, height: 15) }
}
