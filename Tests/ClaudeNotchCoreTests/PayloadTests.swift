import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct PayloadTests {
    func decode(_ json: String) throws -> HookPayload { try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8)) }

    @Test func statusLinePayloadWithObjectModelDecodes() throws {
        // The shape Claude Code's status line actually sends: `model` is an object, and there is no hook_event_name.
        let p = try decode(
            #"{"session_id":"s1","cwd":"/p","model":{"id":"claude-opus-5-5","display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":93,"resets_at":1795600000}},"context_window":{"context_window_size":1000000}}"#
        )
        #expect(p.sessionId == "s1" && p.model == "claude-opus-5-5")
        #expect(QuotaState.parse(p.rateLimits)?.fiveHour?.usedPercent == 93)
        if case .number(let n)? = p.contextWindow?["context_window_size"] {
            #expect(n == 1_000_000)
        } else {
            Issue.record("no context window")
        }
    }

    @Test func wrongTypedFieldsBecomeNilWithoutFailingThePayload() throws {
        let cases = [
            #"{"session_id":"s1","message":{"x":1}}"#, #"{"session_id":"s1","reason":42}"#,
            #"{"session_id":"s1","tool_name":["a"]}"#, #"{"session_id":"s1","prompt":true}"#,
            #"{"session_id":"s1","model":123}"#, #"{"session_id":"s1","agent_id":{"a":1}}"#,
        ]
        for c in cases {
            let p = try decode(c)
            #expect(p.sessionId == "s1", "\(c)")  // the rest of the payload survives
        }
        #expect(try decode(#"{"session_id":"s1","message":{"x":1}}"#).message == nil)
        #expect(try decode(#"{"session_id":"s1","model":"m"}"#).model == "m")
    }

    @Test func truncationCapsFreeTextAtAnyDepth() {
        let big = String(repeating: "x", count: 50_000)
        var p = HookPayload(sessionId: "s1", hookEventName: "UserPromptSubmit")
        p.prompt = big; p.lastAssistantMessage = big
        p.toolInput = .object(["content": .string(big), "nested": .array([.object(["deep": .string(big)])]), "n": .number(1)])
        let t = p.truncated(maxChars: 100)
        #expect(t.prompt!.count <= 101 && t.lastAssistantMessage!.count <= 101)
        let enc = String(decoding: (try? JSONEncoder().encode(t)) ?? Data(), as: UTF8.self)
        #expect(enc.count < 2_000)
        #expect(t.sessionId == "s1" && t.hookEventName == "UserPromptSubmit")
    }

    @Test func roundTripsThroughTheWireFormat() throws {
        var p = HookPayload(sessionId: "s1", hookEventName: "PermissionRequest", toolName: "Bash")
        p.agentId = "a1"; p.toolUseId = "t1"
        let env = HookEnvelope(payload: p, expectsReply: true)
        let back = try HookEnvelope.decode(env.encodedLine().dropLast())
        #expect(back.payload == p && back.expectsReply)
    }
}
