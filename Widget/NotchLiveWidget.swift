import ActivityKit
import AppIntents
import ClaudeNotchCore
import SwiftUI
import WidgetKit

@main struct ClaudeNotchWidgetBundle: WidgetBundle {
    var body: some Widget { ClaudeNotchActivity() }
}

private let coral = Color(red: 0.85, green: 0.47, blue: 0.34)
private let amber = Color(red: 1.0, green: 0.72, blue: 0.2)

extension NotchActivityState.Phase {
    var tint: Color {
        switch self {
        case .needsYou: amber
        case .working: coral
        case .done: .green
        case .idle: .gray
        }
    }
    var symbol: String { self == .done ? "checkmark" : "sparkle" }
}

extension NotchActivityState.Kind {
    var tint: Color {
        switch self {
        case .approval, .question, .input: amber
        case .failed: .red
        case .review: .green
        case .working: coral
        case .idle: .gray
        }
    }
}

private let orange = Color(red: 0.97, green: 0.52, blue: 0.18)

extension NotchActivityState.Phase {
    /// Waveform colour: orange while agents run, amber when you are needed, grey otherwise.
    var waveTint: Color {
        switch self {
        case .working: orange
        case .needsYou: amber
        default: .gray
        }
    }
    var isActive: Bool { self == .working || self == .needsYou }
}

/// The Claude tile, standing in for album art: tinted by state, with a checkmark when everything is done.
struct Tile: View {
    let phase: NotchActivityState.Phase
    var size: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [phase.tint, phase.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: phase.symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95)))
    }
}

/// Music-style waveform: animated bars while active, flat grey dots when idle.
struct Wave: View {
    let phase: NotchActivityState.Phase
    var size: CGFloat = 16
    var body: some View {
        if phase.isActive {
            Image(systemName: "waveform").font(.system(size: size, weight: .semibold)).foregroundStyle(phase.waveTint)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeating)
        } else {
            HStack(spacing: 2.5) {
                ForEach(0..<6, id: \.self) { _ in Circle().fill(Color.gray.opacity(0.7)).frame(width: 2.5, height: 2.5) }
            }
        }
    }
}

struct LimitBar: View {
    let label: String
    let fraction: Double
    var body: some View {
        let tint: Color = fraction >= 0.9 ? .red : (fraction >= 0.75 ? amber : .blue)
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            ProgressView(value: fraction).tint(tint)
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

struct RowView: View {
    let row: NotchActivityState.Row
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(row.kind.tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if row.subagents > 0 {
                        Label("\(row.subagents)", systemImage: "arrow.triangle.branch").font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let since = row.since {
                        Text(since, style: .timer).font(.system(size: 10, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(maxWidth: 48, alignment: .trailing)
                    }
                }
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            RowActions(row: row)
        }
    }
}

struct RowActions: View {
    let row: NotchActivityState.Row
    var body: some View {
        if row.kind == .review {
            Button(intent: MarkReviewedIntent(sessionId: row.id)) { Text("Done") }.buttonStyle(.bordered).controlSize(.mini)
        } else if row.kind == .question || row.kind == .input {
            Button(intent: OpenSessionIntent(sessionId: row.id)) { Text("Open") }.buttonStyle(.bordered).controlSize(.mini)
        }
    }
}

struct ApprovalView: View {
    let a: NotchActivityState.Approval
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(a.project) · \(a.tool)\(a.fromSubagent ? " (subagent)" : "")")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(amber)
            Text(a.command).font(.system(size: 11, design: .monospaced)).lineLimit(3)
            HStack(spacing: 8) {
                Button(intent: AllowIntent(sessionId: a.sessionId, requestId: a.requestId)) {
                    Text("Allow").frame(maxWidth: .infinity)
                }.tint(.green)
                Button(intent: DenyIntent(sessionId: a.sessionId, requestId: a.requestId)) {
                    Text("Deny").frame(maxWidth: .infinity)
                }.tint(.red)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

extension NotchActivityState {
    /// One line for the header: the most urgent session and what it is doing.
    var lead: String {
        guard let r = rows.first else { return "No active sessions" }
        return "\(r.name) · \(r.detail)"
    }
}

/// What sits under the header: the approval if there is one, otherwise the other sessions, then the two limits in one row.
struct ActivityBody: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = state.approval {
                ApprovalView(a: a)
            } else {
                ForEach(state.rows.dropFirst()) { RowView(row: $0) }
                if let r = state.rows.first, r.kind == .review || r.kind == .question || r.kind == .input { RowActions(row: r) }
            }
            if state.more > 0 { Text("+\(state.more) more").font(.system(size: 10)).foregroundStyle(.secondary) }
            if state.fiveHour != nil || state.weekly != nil {
                HStack(spacing: 10) {
                    if let f = state.fiveHour { LimitBar(label: "5h", fraction: f) }
                    if let w = state.weekly { LimitBar(label: "wk", fraction: w) }
                }
            }
        }
    }
}

/// Header shared by the expanded island and the banner: tile, headline and the lead session on the left, waveform right.
struct Header: View {
    let state: NotchActivityState
    var body: some View {
        HStack(spacing: 10) {
            Tile(phase: state.phase, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(state.lead).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Wave(phase: state.phase, size: 18)
        }
    }
}

struct Banner: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(state: state)
            ActivityBody(state: state)
        }
        .padding()
    }
}

struct ClaudeNotchActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchAttributes.self) { ctx in
            Banner(state: ctx.state).opacity(ctx.isStale ? 0.5 : 1)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Tile(phase: s.phase, size: 40) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.headline).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(s.lead).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) { Wave(phase: s.phase, size: 18) }
                DynamicIslandExpandedRegion(.bottom) { ActivityBody(state: s) }
            } compactLeading: {
                Tile(phase: s.phase, size: 22)
            } compactTrailing: {
                Wave(phase: s.phase, size: 14)
            } minimal: {
                Tile(phase: s.phase, size: 22)
            }
            .keylineTint(s.phase.tint)
        }
    }
}
