import AppIntents
import NotchbotCore
import SwiftUI

// The island's views. They live in Shared so the widget draws them and the app can render the same views to PNG
// (`Notchbot --snapshot <dir>`) for docs and for checking layout without the real island.
// Styled after the system media island: big artwork, a bold title over a grey subtitle, a waveform on the right,
// no outlines, generous continuous corners.

private struct IslandScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    /// Size multiplier for the island's type and icons (from settings, carried in `NotchActivityState.scale`).
    var islandScale: CGFloat {
        get { self[IslandScaleKey.self] }
        set { self[IslandScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.islandScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View { content.font(.system(size: size * scale, weight: weight, design: design)) }
}

extension View {
    /// A system font at `size` points times the island's scale.
    func sfont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
    func islandScale(_ s: Double) -> some View { environment(\.islandScale, CGFloat(s)) }
}

enum Island {
    /// Extra inset on every outer edge of the expanded island, on top of the system's own margin.
    static let inset: CGFloat = 17
    /// Least height of the idle island's body, so the system keeps its rounded-rectangle shape instead of a pill.
    static let idleMinHeight: CGFloat = 64
    /// The logo in the compact island, and the waveform beside it, sized from it: the tallest bar is this fraction of
    /// the logo's height, so the two always read as a pair.
    static let compactIcon: CGFloat = 16
    static let compactWaveRatio: CGFloat = 0.7
    static let badgeRed = Color(red: 1.0, green: 0.27, blue: 0.23)  // the system badge red
    static let coral = Color(red: 0.851, green: 0.467, blue: 0.341)  // #D97757
    /// The robot's three tones. Change these to recolour the logo.
    static let robotBase = coral
    static let robotLight = Color(red: 0.933, green: 0.604, blue: 0.486)  // #EE9A7C
    static let robotShadow = Color(red: 0.663, green: 0.333, blue: 0.227)  // #A9553A
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.0)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let surface = Color.white.opacity(0.08)
    /// Cards inside the island. Near-concentric with the island's ~22pt corner across its ~16pt margin (strictly
    /// concentric would be ~6pt, which reads boxy at card size); nested boxes step down again (`innerRadius`).
    static let panelRadius: CGFloat = 12
    static let innerRadius: CGFloat = 8

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

/// The app's mark: a small 8-bit robot (antenna, boxy head, ear nubs, two eyes, a mouth slot), an original sprite on a
/// 16 x 14 grid. `L`, `M` and `D` are its highlight, base and shadow tones. A size that is a multiple of 16pt puts
/// every pixel on a whole device pixel (16pt = 2px a pixel on a Retina screen, 32pt = 4px).
struct RobotMark: Shape {
    static let grid = [
        ".......LL.......",
        ".......MM.......",
        ".......MM.......",
        "...LLLLLLLLLL...",
        "..MMMMMMMMMMMM..",
        "..MMMMMMMMMMMM..",
        "MMMMMMMMMMMMMMMM",
        "MMMM..MMMM..MMMM",
        "MMMM..MMMM..MMMM",
        "MMMMMMMMMMMMMMMM",
        "..MMMM....MMMM..",
        "..MMMMMMMMMMMM..",
        "..DDDDDDDDDDDD..",
        "...DDDDDDDDDD...",
    ]
    /// The tones to draw; nil draws every filled pixel as one solid shape (the menu-bar glyph).
    var tones: Set<Character>?

    func path(in r: CGRect) -> Path {
        let cols = CGFloat(Self.grid[0].count), rows = CGFloat(Self.grid.count)
        let cell = min(r.width / cols, r.height / rows)
        let ox = r.midX - cols * cell / 2, oy = r.midY - rows * cell / 2
        let bleed = cell * 0.01  // neighbouring runs overlap a hair so no seam shows between them
        var p = Path()
        for (y, row) in Self.grid.enumerated() {
            let cells = Array(row)
            var x = 0
            while x < cells.count {
                let tone = cells[x]
                guard tone != ".", tones?.contains(tone) ?? true else { x += 1; continue }
                var end = x
                while end < cells.count, cells[end] == tone { end += 1 }
                p.addRect(
                    CGRect(
                        x: ox + CGFloat(x) * cell - bleed, y: oy + CGFloat(y) * cell - bleed,
                        width: CGFloat(end - x) * cell + bleed * 2, height: cell + bleed * 2))
                x = end
            }
        }
        return p
    }
}

/// The robot in its three tones.
struct RobotView: View {
    var body: some View {
        ZStack {
            RobotMark(tones: ["D"]).fill(Island.robotShadow)
            RobotMark(tones: ["M"]).fill(Island.robotBase)
            RobotMark(tones: ["L"]).fill(Island.robotLight)
        }
    }
}

/// Stands in for album art: the robot mark on its own, no tile. It does not change colour with state;
/// the waveform carries that, and the round red badge counts sessions waiting for review.
struct Artwork: View {
    var size: CGFloat
    /// Finished sessions waiting for review; a round red count on the robot's top right, like an app-icon badge.
    var badge = 0
    var body: some View {
        // The badge sits on the corner and the robot is inset to make room, because the compact region clips anything
        // that sticks out of the view's frame.
        let d = size * 0.8  // badge diameter
        let pad = badge > 0 ? d * 0.4 : 0
        RobotView()
            .frame(width: size, height: size)
            .padding(.top, pad).padding(.trailing, pad)
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)")
                        .font(.system(size: d * 0.62, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
                        .frame(minWidth: d, minHeight: d)
                        .padding(.horizontal, badge > 9 ? d * 0.12 : 0)
                        .background(Capsule().fill(Island.badgeRed))
                        .overlay(Capsule().strokeBorder(.black, lineWidth: max(1, d * 0.1)))
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
    static let minBars = 5

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
            HStack(spacing: height * 0.2) {
                ForEach(0..<5, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.7)).frame(width: height * 0.2, height: height * 0.2)
                }
            }
            .frame(height: height)
        } else {
            // At least `minBars` bars so one agent still reads as a waveform; agents beyond that add bars (up to
            // `maxBars`), and subagents are the thinner ones at the end.
            let total = max(main + subs, Self.minBars)
            HStack(alignment: .center, spacing: height * 0.14) {
                ForEach(0..<total, id: \.self) { i in
                    let isSub = i >= main && i < main + subs
                    // Fixed-size bar scaled vertically: the layout never changes between beats, so the system's
                    // snapshot can't catch the bars collapsed or missing mid-animation.
                    Capsule().fill(tint)
                        .frame(width: height * (isSub ? 0.12 : 0.17), height: height * (isSub ? 0.75 : 1))
                        .scaleEffect(y: Self.level(i, pulse))
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
    @Environment(\.islandScale) private var k
    var body: some View {
        let h = height * k
        Text(title).font(.system(size: h * 0.42, weight: .semibold)).lineLimit(1)
            .foregroundStyle(filled ? Color.white : tint == .white ? Color.white : tint)
            .padding(.horizontal, h * 0.45)
            .frame(maxWidth: stretch ? .infinity : nil, minHeight: h, maxHeight: h)
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
    @Environment(\.islandScale) private var k
    var body: some View {
        HStack(spacing: 3 * k) {
            if let icon { Image(systemName: icon).sfont(size: 9, weight: .bold) }
            label
        }
        .sfont(size: 11, weight: .semibold).monospacedDigit().lineLimit(1).fixedSize()
        .foregroundStyle(tint ?? Color.white.opacity(0.7))
        .padding(.horizontal, 7 * k).padding(.vertical, 3 * k)
        .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.1 : 0.18)))
        .fixedSize()
    }
}

extension Badge where Label == Text {
    init(_ text: String, tint: Color? = nil, icon: String? = nil) {
        self.init(tint: tint, icon: icon) { Text(text) }
    }
}

/// A labelled stat pill: an optional glyph, the value in bright type and what it measures in dim type, so the island
/// explains itself without hover (Live Activities get no pointer events).
struct Stat<Glyph: View, Value: View>: View {
    var label: String
    var tint: Color? = nil
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var value: Value
    @Environment(\.islandScale) private var k
    var body: some View {
        HStack(spacing: 4 * k) {
            glyph.foregroundStyle(tint ?? Color.white.opacity(0.6))
            value.sfont(size: 11, weight: .semibold).foregroundStyle(tint ?? Color.white.opacity(0.9))
            Text(label).sfont(size: 11, weight: .medium).foregroundStyle(Color.white.opacity(0.45))
        }
        .monospacedDigit().lineLimit(1).fixedSize()
        .padding(.horizontal, 7 * k).padding(.vertical, 3 * k)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }
}

extension Stat where Value == Text {
    init(value: String, label: String, tint: Color? = nil, @ViewBuilder glyph: () -> Glyph) {
        self.init(label: label, tint: tint, glyph: glyph) { Text(value) }
    }
}

extension Stat where Glyph == EmptyView {
    init(label: String, tint: Color? = nil, @ViewBuilder value: () -> Value) {
        self.init(label: label, tint: tint, glyph: { EmptyView() }, value: value)
    }
}

/// A tiny progress ring, used for context-window fill.
struct Ring: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 10
    @Environment(\.islandScale) private var k
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.04, min(1, fraction))).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size * k, height: size * k)
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
                Text(p.session).sfont(size: 14, weight: .semibold).foregroundStyle(.white).lineLimit(1)
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
            Text(p.text).sfont(size: 15, weight: .semibold).foregroundStyle(.white).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !p.options.isEmpty {
                // Read-only: the answer is given in Claude itself.
                HStack(spacing: 5) {
                    ForEach(p.options, id: \.self) { o in
                        Text(o).sfont(size: 12, weight: .medium).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
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
        Text(p.text).sfont(size: 12.5, weight: .medium, design: .monospaced).foregroundStyle(.white.opacity(0.92))
            .lineLimit(2).padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Island.innerRadius, style: .continuous).fill(Color.black.opacity(0.55)))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if !p.canAnswer {
                Button(intent: OpenSessionIntent(sessionId: p.sessionId)) {
                    Pill(title: "Open", tint: Island.coral, filled: true, height: 30)
                }
                Text(p.isQuestion ? "Answer it in Claude" : "Answer it in your terminal").sfont(size: 12)
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
    @Environment(\.islandScale) private var k
    var body: some View {
        // Live Activities don't deliver taps to a button hidden behind other content, so the tappable regions are the
        // visible header and detail text themselves; the actions on the right keep their own buttons.
        VStack(alignment: .leading, spacing: 5) {
            Button(intent: OpenSessionIntent(sessionId: row.id)) {
                HStack(spacing: 6) {
                    if !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(row.name).sfont(size: 14, weight: .semibold).foregroundStyle(.white).lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let b = row.branch { Badge(b, icon: "arrow.triangle.branch") }
                    Spacer(minLength: 6)
                    status
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 5) {
                Button(intent: OpenSessionIntent(sessionId: row.id)) {
                    Text(row.detail)
                        .sfont(size: 12.5, design: row.kind == .approval ? .monospaced : .default)
                        .foregroundStyle(row.kind.needsYou ? Color.white.opacity(0.85) : Island.secondary)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                trailing
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Island.panelRadius, style: .continuous)
                .fill(row.kind.needsYou ? Island.amber.opacity(0.10) : Island.surface))
    }

    @ViewBuilder private var status: some View {
        if row.kind == .working, let since = row.since {
            Badge(tint: Island.coral) {
                Text(since, style: .timer).multilineTextAlignment(.center).frame(width: 36 * k)
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
                EmptyView()
            case .working, .idle:
                if row.subagentTotal > 0 {
                    let running = row.subagents > 0
                    Stat(
                        value: "\(running ? row.subagents : row.subagentTotal)",
                        label: running ? (row.subagents == 1 ? "subagent" : "subagents") : "done",
                        tint: running ? Island.coral : nil
                    ) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").sfont(size: 9, weight: .bold)
                    }
                }
                if row.linesAdded + row.linesRemoved > 0 {
                    Stat(label: "lines") {
                        Text("+\(row.linesAdded)").foregroundStyle(Island.green)
                            + Text(" −\(row.linesRemoved)").foregroundStyle(Island.red)
                    }
                }
                // Neutral until the window is filling up (amber > 65 %, red > 85 %).
                if let ctx = row.context {
                    let full = ctx > 0.65
                    Stat(value: "\(Int(ctx * 100))%", label: "context", tint: full ? Island.context(ctx) : nil) {
                        Ring(fraction: ctx, tint: full ? Island.context(ctx) : Color.white.opacity(0.8))
                    }
                }
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

/// One line: the two plan limits as short meters with when each resets, and the pager when there is more than one
/// page.
struct Footer: View {
    let state: NotchActivityState
    @Environment(\.islandScale) private var k
    var body: some View {
        // Bars are always shown. When the pager leaves too little room the bars get shorter (down to a short 22pt
        // stub, which still reads as a meter), and only then do the limits move onto their own line above the pager.
        // One line, always: the pager never drops below the limits. When it gets tight the bars and then the type
        // shrink, but the bars stay visible.
        ViewThatFits(in: .horizontal) {
            row(bar: 40, size: 11, icon: true)
            row(bar: 28, size: 11, icon: true)
            row(bar: 30, size: 11, icon: false)
            row(bar: 22, size: 10.5, icon: false)
            row(bar: 16, size: 10, icon: false)
        }
        .padding(.horizontal, 4)
    }

    private func row(bar: CGFloat, size: CGFloat, icon: Bool) -> some View {
        HStack(spacing: 8) {
            limits(bar: bar, size: size, icon: icon)
            refresh
            Spacer(minLength: 0)
            pager
        }
    }

    /// Sits right after the limits it refreshes, not after the pager.
    private var refresh: some View {
        Button(intent: RefreshQuotaIntent()) {
            Image(systemName: "arrow.clockwise").sfont(size: 10, weight: .bold).foregroundStyle(.white.opacity(0.85))
                .frame(width: 22 * k, height: 22 * k).background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder private var pager: some View {
        if state.pages > 1 { Pager(state: state).fixedSize() }
    }

    private func limits(bar: CGFloat, size: CGFloat, icon: Bool) -> some View {
        HStack(spacing: 9) {
            if let f = state.fiveHour { limit("5h", f, state.fiveHourReset, bar: bar, size: size, icon: icon, hm: true) }
            if let w = state.weekly { limit("7d", w, state.weeklyReset, bar: bar, size: size, icon: icon) }
        }
    }

    /// "5h ▬▬ 44% 🕒2h": the window, a bar, the percentage, and how long until it resets in one short unit.
    private func limit(
        _ label: String, _ f: Double, _ reset: Date?, bar: CGFloat, size: CGFloat, icon: Bool, hm: Bool = false
    )
        -> some View
    {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Island.secondary)
            Capsule().fill(Color.white.opacity(0.16)).frame(width: bar * k, height: 7 * k)
                .overlay(alignment: .leading) {
                    Capsule().fill(Island.quota(f)).frame(width: max(7 * k, bar * k * min(1, f)), height: 7 * k)
                }
            Text("\(Int((f * 100).rounded()))%").foregroundStyle(.white.opacity(0.85))
            if let reset, let left = Island.shortUntil(reset, hm: hm) {
                HStack(spacing: 2) {
                    if icon { Image(systemName: "clock").sfont(size: 9, weight: .semibold) }
                    Text(left)
                }
                .foregroundStyle(Island.tertiary)
            }
        }
        .monospacedDigit()
        .sfont(size: size, weight: .semibold)
        .fixedSize()
    }
}

extension Island {
    /// Time until `date` in one short unit: "45m", "3h", "4d". Nil once it has passed.
    static func shortUntil(_ date: Date, hm: Bool = false, now: Date = .now) -> String? {
        let s = date.timeIntervalSince(now)
        guard s > 0 else { return nil }
        if hm { return Fmt.untilHM(date, now: now) }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86_400 { return "\(Int((s / 3600).rounded()))h" }
        return "\(Int((s / 86_400).rounded()))d"
    }
}

extension Island {
    /// When a limit resets, as short as it reads: "6 PM" or "6:30 PM" today / within a day, "Tue 5 AM" beyond.
    static func resetLabel(_ date: Date, now: Date = .now) -> String {
        let f = DateFormatter()
        let minute = Calendar.current.component(.minute, from: date)
        let clock = minute == 0 ? "h a" : "h:mm a"
        f.dateFormat = date.timeIntervalSince(now) < 20 * 3600 ? clock : "EEE " + clock
        return f.string(from: date)
    }
}

// MARK: - Pager

/// ‹ dots ›: pages through the sessions, since a Live Activity can't scroll. Each tap asks the app for the next page
/// (wrapping around); the app also turns pages by itself while nobody is tapping.
struct Pager: View {
    let state: NotchActivityState
    @Environment(\.islandScale) private var k
    var body: some View {
        HStack(spacing: 5) {
            Button(intent: PageIntent(forward: false)) { arrow("chevron.left") }
            HStack(spacing: 4) {
                ForEach(0..<min(state.pages, 8), id: \.self) { i in
                    Capsule().fill(Color.white.opacity(i == state.page ? 0.9 : 0.25))
                        .frame(width: (i == state.page ? 12 : 5) * k, height: 5 * k)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.page)
            Button(intent: PageIntent(forward: true)) { arrow("chevron.right") }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).sfont(size: 10, weight: .bold).foregroundStyle(.white.opacity(0.85))
            .frame(width: 22 * k, height: 22 * k).background(Circle().fill(Color.white.opacity(0.12))).contentShape(Circle())
    }
}

// MARK: - Regions

/// The header: how many agents, then badges for what needs you, what is working and how many subagents run.
struct IslandTitle: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 6) {
            IslandHeadline(state: state)
            Spacer(minLength: 6)
            IslandBadges(state: state)
        }
    }
}

/// "N agents". On the island it sits in the leading region, up beside the cutout.
struct IslandHeadline: View {
    let state: NotchActivityState
    var body: some View {
        Text(state.sessions == 0 ? "All quiet" : state.sessions == 1 ? "1 agent" : "\(state.sessions) agents")
            .sfont(size: 16, weight: .semibold).foregroundStyle(.white).lineLimit(1)
            .fixedSize()
    }
}

/// What needs you, what is working, how many subagents run. On the island it sits in the trailing region. The badges
/// are fixed-size, so the least urgent ones drop out when there isn't room for all of them.
struct IslandBadges: View {
    let state: NotchActivityState
    var body: some View {
        ViewThatFits(in: .horizontal) {
            badges(working: true, subagents: true)
            badges(working: true, subagents: false)
            badges(working: false, subagents: false)
        }
    }

    private func badges(working: Bool, subagents: Bool) -> some View {
        HStack(spacing: 6) {
            if state.needsYou > 0 { Badge("\(state.needsYou) need\(state.needsYou == 1 ? "s" : "") you", tint: Island.amber) }
            if working, state.working > 0 { Badge("\(state.working) working", tint: Island.coral) }
            if subagents, state.subagentsRunning > 0 {
                Badge(
                    "\(state.subagentsRunning) subagent\(state.subagentsRunning == 1 ? "" : "s")",
                    icon: "point.3.connected.trianglepath.dotted")
            }
        }
    }
}

/// The gear at the island's top right: opens NotchBot's settings without going through the menu bar.
struct SettingsGear: View {
    var body: some View {
        Button(intent: OpenSettingsIntent()) {
            Image(systemName: "gearshape.fill").sfont(size: 11, weight: .semibold).foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Everything under the header.
struct IslandBody: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = state.prompt { PromptPanel(p: p) }
            ForEach(state.rows) { SessionRow(row: $0) }
            Footer(state: state).padding(.top, 4)
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
    /// False on the island, where "All quiet" already sits up beside the cutout (and the compact view shows the logo).
    var header = true
    @Environment(\.islandScale) private var k
    var body: some View {
        VStack(alignment: .leading, spacing: header ? 12 : 8) {
            if !header {
                Text("No Claude Code sessions running").sfont(size: 13).foregroundStyle(Island.secondary)
                    .lineLimit(1).padding(.horizontal, 4)
            } else {
                HStack(spacing: 12) {
                    Artwork(size: 32 * k)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All quiet").sfont(size: 16, weight: .semibold).foregroundStyle(.white)
                        Text("No Claude Code sessions running").sfont(size: 13).foregroundStyle(Island.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            if state.fiveHour != nil || state.weekly != nil {
                HStack(alignment: .bottom, spacing: 16) {
                    if let f = state.fiveHour { meter("5-hour limit", f, state.fiveHourReset, hm: true) }
                    if let w = state.weekly { meter("Weekly limit", w, state.weeklyReset) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Island.panelRadius, style: .continuous).fill(Island.surface))
            }
        }
    }

    private func meter(_ label: String, _ f: Double, _ reset: Date?, hm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).sfont(size: 12, weight: .semibold).foregroundStyle(Island.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text("\(Int((f * 100).rounded()))%").sfont(size: 15, weight: .semibold).foregroundStyle(.white)
                    .monospacedDigit().lineLimit(1).fixedSize()
            }
            Capsule().fill(Color.white.opacity(0.16)).frame(height: 6 * k)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Island.quota(f)).frame(width: max(6 * k, g.size.width * min(1, f)))
                    }
                }
            Group {
                if let reset, reset > .now {
                    Text("Resets \(Island.shortUntil(reset, hm: hm) ?? "soon")")
                } else {
                    Text(f == 0 ? "Not used yet" : "Reset time unknown")
                }
            }
            .sfont(size: 11).foregroundStyle(Island.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The compact presentation: the logo on the left of the cutout, the waveform on the right.
struct IslandCompactLeading: View {
    let state: NotchActivityState
    var body: some View { Artwork(size: Island.compactIcon, badge: state.reviews) }
}

struct IslandCompactTrailing: View {
    let state: NotchActivityState
    var body: some View {
        // An explicit size: the compact region otherwise has nothing to measure when the system snapshots it.
        let h = Island.compactIcon * Island.compactWaveRatio
        AgentWave(state: state, height: h).frame(width: 30, height: h)
    }
}
