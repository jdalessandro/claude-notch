import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct SafeZoneTests {
    @Test func eachSideIsHalfOfWhatIsLeftBesideTheCutout() {
        // 350 wide island, 87 pt cutout: (350 - 87 - 2*4 margin - 2*20 padding) / 2
        #expect(SafeZone.sideWidth(islandWidth: 350, cutoutWidth: 87) == 107.5)
        #expect(SafeZone.sideWidth(islandWidth: 320, cutoutWidth: 87) == 92.5)
    }

    @Test func aWiderCutoutOrNarrowerIslandNeverGrowsTheSide() {
        var last = Double.infinity
        for cutout in stride(from: 40.0, through: 300, by: 20) {
            let s = SafeZone.sideWidth(islandWidth: 350, cutoutWidth: cutout)
            #expect(s <= last)
            last = s
        }
        #expect(SafeZone.sideWidth(islandWidth: 300, cutoutWidth: 87) < SafeZone.sideWidth(islandWidth: 400, cutoutWidth: 87))
    }

    @Test func degradesGracefullyWhenThereIsNoRoom() {
        #expect(SafeZone.sideWidth(islandWidth: 100, cutoutWidth: 400) == SafeZone.minimumSide)  // never zero or negative
        #expect(SafeZone.sideWidth(islandWidth: 0, cutoutWidth: 0) >= SafeZone.minimumSide)
    }

    @Test func fitsReflectsTheComputedSide() {
        #expect(SafeZone.fits(contentWidth: 107, islandWidth: 350, cutoutWidth: 87))
        #expect(!SafeZone.fits(contentWidth: 108, islandWidth: 350, cutoutWidth: 87))  // the "3 agents · 2 sub" case that was clipped
    }
}
