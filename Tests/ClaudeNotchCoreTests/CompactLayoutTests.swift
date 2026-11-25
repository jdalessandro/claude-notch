import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct CompactLayoutTests {
    @Test func heightGrowsPerRowThenCapsWithOverflowLine() {
        let r = CompactLayout.rowHeight, g = CompactLayout.gap
        #expect(CompactLayout.listHeight(sessionCount: 0) == CompactLayout.emptyHeight)
        #expect(CompactLayout.listHeight(sessionCount: 1) == r)
        #expect(CompactLayout.listHeight(sessionCount: 3) == 3 * r + 2 * g)
        let full = CGFloat(CompactLayout.maxRows) * r + CGFloat(CompactLayout.maxRows - 1) * g
        #expect(CompactLayout.listHeight(sessionCount: CompactLayout.maxRows) == full)
        #expect(CompactLayout.listHeight(sessionCount: CompactLayout.maxRows + 5) == full + CompactLayout.overflowHeight)
    }

    @Test func clickingARowForcesDetailedWithoutChangingTheSavedMode() {
        typealias M = Preferences.ExpandedMode
        #expect(Preferences.resolveExpandedMode(saved: .compact, forcedDetailed: false) == .compact)
        #expect(Preferences.resolveExpandedMode(saved: .compact, forcedDetailed: true) == .detailed)
        #expect(Preferences.resolveExpandedMode(saved: .detailed, forcedDetailed: true) == .detailed)
        #expect(Preferences.resolveExpandedMode(saved: .detailed, forcedDetailed: false) == .detailed)
    }
}
