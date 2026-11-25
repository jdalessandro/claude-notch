import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct HoverGateTests {
    let t0 = Date(timeIntervalSince1970: 1000)
    func at(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

    @Test func opensOnlyAfterDwell() {
        var g = HoverGate(enterDelay: 0.09, exitDelay: 0.32)
        #expect(g.update(inside: true, now: at(0)) == false)
        #expect(g.update(inside: true, now: at(50)) == false)
        #expect(g.update(inside: true, now: at(100)) == true)
    }

    @Test func edgeGrazingNeverOpens() {
        var g = HoverGate()
        for i in 0..<20 { #expect(g.update(inside: i % 2 == 0, now: at(i * 30)) == false) }  // flicker < dwell
    }

    @Test func closesOnlyAfterGracePeriod() {
        var g = HoverGate(enterDelay: 0, exitDelay: 0.32)
        g.update(inside: true, now: at(0)); #expect(g.isHovering)
        #expect(g.update(inside: false, now: at(10)) == true)
        #expect(g.update(inside: false, now: at(200)) == true)
        #expect(g.update(inside: false, now: at(400)) == false)
    }

    @Test func reentryCancelsPendingClose() {
        var g = HoverGate(enterDelay: 0, exitDelay: 0.32)
        g.update(inside: true, now: at(0))
        g.update(inside: false, now: at(100))
        g.update(inside: true, now: at(250))  // came back inside the grace window
        #expect(g.update(inside: false, now: at(400)) == true)  // the grace timer restarted at 400, not 100
        #expect(g.update(inside: false, now: at(800)) == false)
    }

    @Test func resetClearsState() {
        var g = HoverGate(enterDelay: 0, exitDelay: 1); g.update(inside: true, now: at(0)); g.reset()
        #expect(!g.isHovering)
    }
}
