import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct ReviewGateTests {
    let t0 = Date(timeIntervalSince1970: 1000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func reviewedOnlyAfterContinuousViewing() {
        var g = ReviewGate(dwell: 5)
        #expect(g.update(viewing: ["a"], now: at(0)).isEmpty)
        #expect(g.update(viewing: ["a"], now: at(4.9)).isEmpty)
        #expect(g.update(viewing: ["a"], now: at(5)) == ["a"])
    }

    @Test func lookingAwayStartsTheClockOver() {
        var g = ReviewGate(dwell: 5)
        g.update(viewing: ["a"], now: at(0))
        g.update(viewing: [], now: at(3))  // moved the pointer away
        #expect(g.update(viewing: ["a"], now: at(4)).isEmpty)  // back, but only 0 s of the new stretch
        #expect(g.update(viewing: ["a"], now: at(8)).isEmpty)  // 4 s: still short
        #expect(g.update(viewing: ["a"], now: at(9)) == ["a"])
    }

    @Test func eachSessionHasItsOwnClockAndFiresOnce() {
        var g = ReviewGate(dwell: 5)
        g.update(viewing: ["a"], now: at(0))
        #expect(g.update(viewing: ["a", "b"], now: at(5)) == ["a"])  // b only just appeared
        #expect(g.update(viewing: ["b"], now: at(9)).isEmpty)  // a is no longer pending (reviewed)
        #expect(g.update(viewing: ["b"], now: at(10)) == ["b"])
    }

    @Test func nothingBeingViewedNeverFires() {
        var g = ReviewGate(dwell: 1)
        for i in 0..<10 { #expect(g.update(viewing: [], now: at(Double(i))).isEmpty) }
    }
}
