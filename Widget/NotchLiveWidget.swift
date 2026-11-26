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

struct Glyph: View {
    let phase: NotchActivityState.Phase
    var body: some View {
        Image(systemName: phase.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(phase.tint)
    }
}

struct LimitBar: View {
    let label: String
    let fraction: Double
    var body: some View {
        let tint: Color = fraction >= 0.9 ? .red : (fraction >= 0.75 ? amber : .blue)
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            ProgressView(value: fraction).tint(tint)
            Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
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
            if row.kind == .review {
                Button(intent: MarkReviewedIntent(sessionId: row.id)) { Text("Done") }.buttonStyle(.bordered).controlSize(.mini)
            } else if row.kind == .question || row.kind == .input {
                Button(intent: OpenSessionIntent(sessionId: row.id)) { Text("Open") }.buttonStyle(.bordered).controlSize(.mini)
            }
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

struct ActivityBody: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = state.approval { ApprovalView(a: a) }
            ForEach(state.rows.filter { $0.id != state.approval?.sessionId }) { RowView(row: $0) }
            if state.more > 0 {
                Text("+\(state.more) more").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if state.rows.isEmpty { Text("No active sessions").font(.system(size: 11)).foregroundStyle(.secondary) }
            if state.fiveHour != nil || state.weekly != nil {
                VStack(spacing: 3) {
                    if let f = state.fiveHour { LimitBar(label: "5 hour", fraction: f) }
                    if let w = state.weekly { LimitBar(label: "Weekly", fraction: w) }
                }
            }
        }
    }
}

struct Banner: View {
    let state: NotchActivityState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Glyph(phase: state.phase)
                Text(state.headline).font(.headline)
                Spacer()
                if state.subagentsRunning > 0 {
                    Label("\(state.subagentsRunning)", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                }
            }
            ActivityBody(state: state)
        }
        .padding()
    }
}

struct ClaudeNotchActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchAttributes.self) { ctx in
            Banner(state: ctx.state)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Glyph(phase: s.phase) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.needsYou > 0 ? "\(s.needsYou)" : "\(s.working)").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(s.phase.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.headline).font(.headline).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) { ActivityBody(state: s) }
            } compactLeading: {
                Glyph(phase: s.phase)
            } compactTrailing: {
                Text(s.needsYou > 0 ? "\(s.needsYou)" : (s.working > 0 ? "\(s.working)" : "")).foregroundStyle(s.phase.tint)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            } minimal: {
                Glyph(phase: s.phase)
            }
        }
    }
}
