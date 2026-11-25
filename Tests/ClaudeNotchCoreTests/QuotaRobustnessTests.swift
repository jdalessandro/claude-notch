import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct QuotaRobustness {
    func parse(_ json: String) throws -> QuotaState? { QuotaState.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }

    @Test func percentagesAreClampedAndNonFiniteValuesIgnored() throws {
        let q = try #require(
            try parse(#"{"five_hour":{"used_percentage":135},"seven_day":{"used_percentage":-4},"seven_day_x":{"used_percentage":1e30}}"#))
        #expect(q.fiveHour?.usedPercent == 100 && q.sevenDay?.usedPercent == 0)
        #expect(q.windows.last?.usedPercent == 100)  // huge values clamp instead of trapping later
        #expect(QuotaWindow(usedPercent: .nan).usedPercent == 0 && QuotaWindow(usedPercent: .infinity).usedPercent == 0)
    }

    @Test func millisecondTimestampsAreNormalised() throws {
        let q = try #require(try parse(#"{"five_hour":{"used_percentage":10,"resets_at":1795600000000}}"#))
        #expect(q.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_795_600_000))
        #expect(QuotaState.date(fromEpoch: -5) == nil && QuotaState.date(fromEpoch: .nan) == nil)
    }

    @Test func expiredWindowsShowAsFreshlyReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = QuotaState(windows: [
            QuotaWindow(id: "five_hour", usedPercent: 93, resetsAt: now.addingTimeInterval(-60)),
            QuotaWindow(id: "seven_day", usedPercent: 14, resetsAt: now.addingTimeInterval(3600)),
        ])
        let r = q.refreshed(now: now)
        #expect(r.fiveHour?.usedPercent == 0 && r.fiveHour?.resetsAt == nil)  // stale 93% is not shown forever
        #expect(r.sevenDay?.usedPercent == 14)  // still-running window untouched
    }

    @Test func planDetectionCoversProvidersGatewaysAndSettingsEnv() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let cj = d.appendingPathComponent(".claude.json")
        try #"{"oauthAccount":{"billingType":"stripe_subscription","organizationType":"claude_max"}}"#.write(
            to: cj, atomically: true, encoding: .utf8)
        let sub = BillingMode.subscription(plan: "Max")
        #expect(PlanDetector.detect(env: [:], claudeJSON: cj) == sub)
        for flag in PlanDetector.providerFlags { #expect(PlanDetector.detect(env: [flag: "1"], claudeJSON: cj) == .api, "\(flag)") }
        #expect(PlanDetector.detect(env: ["CLAUDE_CODE_USE_BEDROCK": "0"], claudeJSON: cj) == sub)  // explicitly off
        #expect(PlanDetector.detect(env: ["ANTHROPIC_BASE_URL": "gateway.corp:8080"], claudeJSON: cj) == .api)  // scheme-less
        #expect(PlanDetector.detect(env: ["ANTHROPIC_BASE_URL": "https://API.Anthropic.com"], claudeJSON: cj) == sub)  // casing
        // A GUI-launched app doesn't inherit shell exports, so settings.json's env block and apiKeyHelper count too.
        let s1 = d.appendingPathComponent("s1.json"), s2 = d.appendingPathComponent("s2.json")
        try #"{"env":{"ANTHROPIC_API_KEY":"k"}}"#.write(to: s1, atomically: true, encoding: .utf8)
        try #"{"apiKeyHelper":"/bin/key"}"#.write(to: s2, atomically: true, encoding: .utf8)
        #expect(PlanDetector.detect(env: [:], claudeJSON: cj, settings: s1) == .api)
        #expect(PlanDetector.detect(env: [:], claudeJSON: cj, settings: s2) == .api)
        #expect(PlanDetector.detect(env: [:], claudeJSON: cj, settings: d.appendingPathComponent("missing.json")) == sub)
    }
}
