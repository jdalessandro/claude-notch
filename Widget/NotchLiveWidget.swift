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
            IslandExpanded(state: ctx.state).islandScale(ctx.state.scale).padding(16).opacity(ctx.isStale ? 0.6 : 1)
                .activityBackgroundTint(.black)
                .environment(\.colorScheme, .dark)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                // Like Apple Music: the header goes up into the band beside the cutout (leading / trailing) instead
                // of leaving it empty above the content, so the island's insets come out even on every side.
                // `Island.inset` is added on every outer edge, on top of the system's own margin, to keep them even.
                DynamicIslandExpandedRegion(.leading) {
                    IslandHeadline(state: s).islandScale(s.scale)
                        .padding(.leading, Island.inset + 4).padding(.top, Island.inset)
                        .opacity(ctx.isStale ? 0.6 : 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.sessions > 0 {
                        IslandBadges(state: s).islandScale(s.scale)
                            .padding(.trailing, Island.inset).padding(.top, Island.inset)
                            .opacity(ctx.isStale ? 0.6 : 1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if s.sessions == 0 { IslandIdle(state: s, header: false) } else { IslandBody(state: s) }
                    }
                    .islandScale(s.scale)
                    .padding(.horizontal, Island.inset)
                    .padding(.top, 4)
                    .padding(.bottom, Island.inset)
                    .opacity(ctx.isStale ? 0.6 : 1)
                }
            } compactLeading: {
                IslandCompactLeading(state: s)
            } compactTrailing: {
                IslandCompactTrailing(state: s)
            } minimal: {
                Artwork(size: Island.compactIcon)
            }
            .keylineTint(Island.coral)
        }
    }
}
