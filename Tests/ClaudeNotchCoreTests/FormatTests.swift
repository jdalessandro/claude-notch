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
        #expect(Fmt.untilHM(now.addingTimeInterval(2 * 3_600 + 35 * 60), now: now) == "2h 35m")
        #expect(Fmt.untilHM(now.addingTimeInterval(35 * 60), now: now) == "35m")
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

    @Test func markdownIsFlattenedButInlineMarksSurvive() {
        let md = "## Done\n\nAdded **three** tests:\n- `RetryTests.swift`\n- see [docs](https://x.y)\n```swift\nlet x = 1\n```\n1. ship it"
        let inline = Fmt.inlineMarkdown(md)
        #expect(inline == "Done Added **three** tests: `RetryTests.swift` see [docs](https://x.y) ship it")
        #expect(!inline.contains("let x"))  // fenced code dropped
        #expect(Fmt.plainText(md) == "Done Added three tests: RetryTests.swift see docs ship it")
        #expect(Fmt.inlineMarkdown("") == "" && Fmt.plainText("   \n\n") == "")
    }

    @Test func syntheticPromptsAreRecognised() {
        for s in [
            #"<agent-message from="a1"> [Subagent hand-back] ..."#, "<task-notification>x</task-notification>",
            "<system-reminder>be careful</system-reminder>", "  <command-name>/clear</command-name>", "[Request interrupted by user]",
        ] { #expect(Fmt.isSyntheticPrompt(s), "\(s)") }
        for s in ["Fix the flaky test", "use <div> for the layout", "What does <T> mean in Swift?", "1 < 2 is true"] {
            #expect(!Fmt.isSyntheticPrompt(s), "\(s)")  // real prompts that merely mention angle brackets
        }
    }
}
