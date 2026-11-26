import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main struct NotchLiveBundle: WidgetBundle {
    var body: some Widget { NotchLiveActivity() }
}

private let coral = Color(red: 0.85, green: 0.47, blue: 0.34)

struct Banner: View {
    let state: NotchAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkle").foregroundStyle(coral)
                Text(state.headline).font(.headline)
                Spacer()
                Text("\(state.agents) agents").font(.caption).foregroundStyle(.secondary)
            }
            Text(state.detail).font(.system(.caption, design: .monospaced)).lineLimit(2)
            if state.approvalPending {
                HStack {
                    Button(intent: AllowIntent()) { Text("Allow") }.tint(.green)
                    Button(intent: DenyIntent()) { Text("Deny") }.tint(.red)
                }
            }
        }
        .padding()
    }
}

struct NotchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchAttributes.self) { ctx in
            Banner(state: ctx.state)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "sparkle").foregroundStyle(coral) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(ctx.state.agents)").foregroundStyle(.white) }
                DynamicIslandExpandedRegion(.center) { Text(ctx.state.headline).font(.headline).foregroundStyle(.white) }
                DynamicIslandExpandedRegion(.bottom) { Banner(state: ctx.state) }
            } compactLeading: {
                Image(systemName: "sparkle").foregroundStyle(coral)
            } compactTrailing: {
                Text("\(ctx.state.needsYou)").foregroundStyle(.white)
            } minimal: {
                Image(systemName: "sparkle").foregroundStyle(coral)
            }
        }
    }
}
