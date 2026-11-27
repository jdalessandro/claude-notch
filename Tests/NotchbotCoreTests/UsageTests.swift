import Foundation
import Testing

@testable import NotchbotCore

@Suite struct Usage {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("u-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    @Test func plansDetectedFromAccountAndEnv() throws {
        let d = try tmp(); let f = d.appendingPathComponent("c.json")
        try
            #"{"oauthAccount":{"billingType":"stripe_subscription","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_5x"}}"#
            .write(to: f, atomically: true, encoding: .utf8)
        #expect(PlanDetector.detect(env: [:], claudeJSON: f) == .subscription(plan: "Max 5x"))
        #expect(PlanDetector.detect(env: ["ANTHROPIC_API_KEY": "x"], claudeJSON: f) == .api)
        #expect(PlanDetector.detect(env: ["ANTHROPIC_BASE_URL": "https://gw.example.com"], claudeJSON: f) == .api)
        #expect(
            PlanDetector.detect(env: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"], claudeJSON: f) == .subscription(plan: "Max 5x"))
        #expect(PlanDetector.detect(env: [:], claudeJSON: d.appendingPathComponent("missing.json")) == .api)
    }

    @Test func windowsBucketByTimeAndDedupeRequests() throws {
        let root = try tmp(); let proj = root.appendingPathComponent("p");
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
        func line(_ rid: String, _ ago: TimeInterval, out: Int) -> String {
            let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago))
            return
                #"{"type":"assistant","requestId":"\#(rid)","timestamp":"\#(ts)","message":{"usage":{"input_tokens":10,"output_tokens":\#(out),"cache_read_input_tokens":1000,"cache_creation_input_tokens":5}}}"#
        }
        let lines = [
            line("a", 600, out: 1), line("a", 600, out: 100),  // streamed twice: counted once, max wins
            line("b", 4 * 3600, out: 200),  // inside 5h
            line("c", 30 * 3600, out: 300),  // inside 7d, outside 5h/today
            line("d", 9 * 86_400, out: 400),
        ]  // outside everything
        try (lines.joined(separator: "\n") + "\n").write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let agg = UsageAggregator(root: root)
        let w = agg.refresh(now: now, calendar: cal)
        #expect(w.fiveHour.output == 300 && w.fiveHour.work == 2 * 15 + 300)  // a(100)+b(200)
        #expect(w.today.output == 300)  // since 00:00Z today
        #expect(w.week.output == 600)  // a+b+c
        // Incremental: appended line is picked up without double counting.
        let h = try FileHandle(forWritingTo: proj.appendingPathComponent("s.jsonl")); try h.seekToEnd()
        try h.write(contentsOf: Data((line("e", 60, out: 7) + "\n").utf8)); try h.close()
        #expect(agg.refresh(now: now, calendar: cal).fiveHour.output == 307)
    }

    @Test func quotaDiscoversPerModelWindowsAndOrdersThem() throws {
        let j = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"seven_day_fable":{"used_percentage":0},"seven_day":{"used_percentage":12},"five_hour":{"used_percentage":82,"resets_at":1795600000},"spend_limit":{"used_percentage":3},"seven_day_bogus":{"nope":1}}"#
                    .utf8))
        let q = QuotaState.parse(j)!
        #expect(q.windows.map(\.title) == ["5-hour limit", "Weekly · all models", "Weekly · Fable"])  // spend_limit/invalid ignored
        #expect(QuotaState.title(for: "seven_day_opus") == "Weekly · Opus")
        #expect(QuotaState.title(for: "seven_day_extra_usage") == "Weekly · Extra usage")
    }

    @Test func quotaParsesStatusLineJSON() throws {
        let j = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"five_hour":{"used_percentage":42.5,"resets_at":1795600000},"seven_day":{"used_percentage":18}}"#.utf8))
        let q = QuotaState.parse(j)!
        #expect(q.fiveHour?.usedPercent == 42.5 && q.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1795600000))
        #expect(q.sevenDay?.fraction == 0.18 && q.sevenDay?.resetsAt == nil)
        #expect(QuotaState.parse(.object([:])) == nil && QuotaState.parse(nil) == nil)
    }
}
