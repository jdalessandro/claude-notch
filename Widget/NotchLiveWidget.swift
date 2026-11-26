import ActivityKit
import ClaudeNotchCore
import SwiftUI
import WidgetKit

@main struct ClaudeNotchWidgetBundle: WidgetBundle {
    var body: some Widget { ClaudeNotchActivity() }
}

/// The island itself. The views are in Shared/IslandViews.swift so the app can snapshot them.
struct ClaudeNotchActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchAttributes.self) { ctx in
            IslandExpanded(state: ctx.state).padding(16).opacity(ctx.isStale ? 0.6 : 1)
                .activityBackgroundTint(.black)
                .environment(\.colorScheme, .dark)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Artwork(size: 52).padding(.leading, 6).padding(.top, 4) }
                DynamicIslandExpandedRegion(.center) { IslandTitle(state: s).padding(.leading, 4).padding(.top, 4) }
                DynamicIslandExpandedRegion(.trailing) { AgentWave(state: s, height: 20).padding(.trailing, 8).padding(.top, 4) }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBody(state: s).padding(.horizontal, 2).opacity(ctx.isStale ? 0.6 : 1)
                }
            } compactLeading: {
                IslandCompactLeading(state: s)
            } compactTrailing: {
                IslandCompactTrailing(state: s)
            } minimal: {
                Artwork(size: 22)
            }
            .keylineTint(Island.coral)
        }
    }
}
