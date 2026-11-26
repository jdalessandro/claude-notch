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
                // The leading / trailing regions sit up beside the cutout, detached from the content, and the compact
                // island already shows the logo and waveform; so the expanded view is one column under the cutout.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        IslandTitle(state: s).padding(.horizontal, 4)
                        IslandBody(state: s)
                    }
                    .padding(.horizontal, 2).opacity(ctx.isStale ? 0.6 : 1)
                }
            } compactLeading: {
                IslandCompactLeading(state: s)
            } compactTrailing: {
                IslandCompactTrailing(state: s)
            } minimal: {
                Artwork(size: 17)
            }
            .keylineTint(Island.coral)
        }
    }
}
