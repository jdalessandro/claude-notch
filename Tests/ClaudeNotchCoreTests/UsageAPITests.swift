import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct UsageAPITests {
    @Test func parsesWindowsAndIgnoresNulls() throws {
        let json =
            #"{"five_hour":{"utilization":39.0,"resets_at":"2026-11-26T23:00:00.412+00:00"},"seven_day":{"utilization":50,"#
            + #""resets_at":"2026-12-01T10:00:00+00:00"},"seven_day_opus":null,"extra_usage":{"utilization":3}}"#
        let q = try #require(UsageAPI.parse(Data(json.utf8)))
        #expect(q.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(q.fiveHour?.usedPercent == 39 && q.sevenDay?.usedPercent == 50)
        #expect(abs((q.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0) - 1_795_734_000.412) < 0.01)
        #expect(q.sevenDay?.resetsAt != nil)
    }

    @Test func rejectsUnexpectedShapes() {
        #expect(UsageAPI.parse(Data("[]".utf8)) == nil)
        #expect(UsageAPI.parse(Data(#"{"error":"x"}"#.utf8)) == nil)
    }

    @Test func readsTheTokenAndNoticesExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ok = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":2000000000000}}"#
        #expect(try UsageAPI.token(fromCredentials: Data(ok.utf8), now: now) == "t")
        let old = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000}}"#
        #expect(throws: UsageAPI.Failure.expiredLogin) { try UsageAPI.token(fromCredentials: Data(old.utf8), now: now) }
        #expect(throws: UsageAPI.Failure.noLogin) { try UsageAPI.token(fromCredentials: Data("{}".utf8), now: now) }
    }

    @Test func renewalKeepsEveryOtherCredentialField() throws {
        let old =
            #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["x"],"subscriptionType":"max"},"#
            + #""other":1}"#
        let resp = #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#
        let now = Date(timeIntervalSince1970: 1000)
        let out = try #require(UsageAPI.merged(credentials: Data(old.utf8), tokenResponse: Data(resp.utf8), now: now))
        let root = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        let o = try #require(root["claudeAiOauth"] as? [String: Any])
        #expect(o["accessToken"] as? String == "a2" && o["refreshToken"] as? String == "r2")
        #expect(o["expiresAt"] as? Int == 4_600_000)
        #expect(o["subscriptionType"] as? String == "max" && (o["scopes"] as? [String]) == ["x"] && root["other"] as? Int == 1)
        #expect(UsageAPI.merged(credentials: Data(old.utf8), tokenResponse: Data("{}".utf8)) == nil)
    }
}
