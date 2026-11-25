import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct FormatTests {
    @Test func tokens() {
        #expect(Fmt.tokens(0) == "0" && Fmt.tokens(999) == "999")
        #expect(Fmt.tokens(1_500) == "1.5k" && Fmt.tokens(12_400) == "12k")
        #expect(Fmt.tokens(1_100_000) == "1.1M")
    }
    @Test func cost() {
        #expect(Fmt.cost(0) == "$0.00" && Fmt.cost(0.004) == "<$0.01" && Fmt.cost(3.2) == "$3.20")
    }
    @Test func durations() {
        #expect(Fmt.duration(-5) == "0s" && Fmt.duration(45) == "45s")
        #expect(Fmt.duration(74) == "1m 14s" && Fmt.duration(3_700) == "1h 1m")
    }
    @Test func resetCountdownUsesLargestUnit() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(Fmt.until(now.addingTimeInterval(6 * 86_400 + 3_600), now: now) == "6d")
        #expect(Fmt.until(now.addingTimeInterval(4 * 3_600 + 300), now: now) == "4h")
        #expect(Fmt.until(now.addingTimeInterval(25 * 60), now: now) == "25m")
        #expect(Fmt.until(now.addingTimeInterval(-10), now: now) == "1m")  // already past: never negative
    }
    @Test func relativeTime() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(Fmt.ago(now.addingTimeInterval(-5), now: now) == "just now")
        #expect(Fmt.ago(now.addingTimeInterval(-180), now: now) == "3m ago")
        #expect(Fmt.ago(now.addingTimeInterval(-7_300), now: now) == "2h ago")
    }
    @Test func statusLabels() {
        #expect(Fmt.label(.needsPermission) == "Needs permission" && Fmt.label(.done) == "Done")
    }
}
