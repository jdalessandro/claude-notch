import ActivityKit
import NotchbotCore
import SwiftUI
import WidgetKit

@main struct NotchbotWidgetBundle: WidgetBundle {
    var body: some Widget { NotchbotActivity() }
}

/// The island itself. The views are in Shared/IslandViews.swift so the app can snapshot them.
struct NotchbotActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NotchAttributes.self) { ctx in
            IslandExpanded(state: ctx.state).islandScale(ctx.state.scale).environment(\.islandStale, ctx.isStale).padding(16).opacity(
                ctx.isStale ? 0.6 : 1
            )
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
                    HStack(spacing: 8) {
                        if s.sessions > 0 { IslandBadges(state: s) }
                        SettingsGear()
                    }
                    .islandScale(s.scale)
                    .padding(.trailing, Island.inset).padding(.top, Island.inset)
                    .opacity(ctx.isStale ? 0.6 : 1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if s.sessions == 0 {
                            // Short content makes the system round the island into a full pill. A minimum height
                            // keeps the usual rounded-rectangle shape even with no limits row to fill it.
                            IslandIdle(state: s, header: false)
                                .frame(maxWidth: .infinity, minHeight: Island.idleMinHeight * s.scale, alignment: .topLeading)
                        } else {
                            IslandBody(state: s)
                        }
                    }
                    .islandScale(s.scale)
                    .environment(\.islandStale, ctx.isStale)
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
                IslandMinimal(state: s)
            }
            .keylineTint(Island.coral)
        }
    }
}
