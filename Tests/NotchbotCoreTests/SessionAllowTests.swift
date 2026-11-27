import Foundation
import Testing

@testable import NotchbotCore

private final class Sink: ReplySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [HookReply] = []
    var sent: [HookReply] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ reply: HookReply) { lock.lock(); _sent.append(reply); lock.unlock() }
}

private func suggestion(tool: String = "Bash", content: String? = "npm install", dest: String = "localSettings") -> JSONValue {
    var rule: [String: JSONValue] = ["toolName": .string(tool)]
    if let content { rule["ruleContent"] = .string(content) }
    return .array([
        .object([
            "type": .string("addRules"), "rules": .array([.object(rule)]), "behavior": .string("allow"),
            "destination": .string(dest),
        ])
    ])
}

@Suite struct SessionAllow {
    @Test func suggestionIsRetargetedToTheSession() throws {
        let r = try #require(PendingPermission.sessionRule(from: suggestion(), tool: "Bash"))
        #expect(r.label == "npm install")
        #expect(r.rule["destination"]?.stringValue == "session" && r.rule["type"]?.stringValue == "addRules")
        #expect(r.rule["behavior"]?.stringValue == "allow")
    }

    @Test func unsafeOrUnusableSuggestionsAreNotOffered() {
        #expect(PendingPermission.sessionRule(from: suggestion(content: nil), tool: "Bash") == nil, "never all of Bash")
        #expect(PendingPermission.sessionRule(from: suggestion(tool: "Write"), tool: "Bash") == nil, "other tool")
        #expect(PendingPermission.sessionRule(from: suggestion(content: String(repeating: "x", count: 600)), tool: "Bash") == nil)
        let setMode = JSONValue.array([.object(["type": .string("setMode"), "mode": .string("acceptEdits")])])
        #expect(PendingPermission.sessionRule(from: setMode, tool: "Edit") == nil)
        #expect(PendingPermission.sessionRule(from: nil, tool: "Bash") == nil)
        // A whole-tool rule is fine for a non-Bash tool (an MCP tool).
        #expect(PendingPermission.sessionRule(from: suggestion(tool: "mcp__x__y", content: nil), tool: "mcp__x__y")?.label == "mcp__x__y")
    }

    @Test func payloadDecodesSuggestionsAndStateOffersScope() throws {
        let json =
            #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm install"}],"behavior":"allow","destination":"localSettings"}]}"#
        let p = try JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
        #expect(p.permissionSuggestions != nil)
        var st = SessionStore()
        _ = st.apply(HookEnvelope(payload: p, expectsReply: true))
        let s = try #require(st.sessions["s1"])
        #expect(s.pending?.sessionScope == "npm install")
        #expect(NotchActivityState.make(sessions: [s], quota: nil).prompt?.sessionScope == "npm install")
        // Not answerable from the island => no offer.
        var st2 = SessionStore()
        _ = st2.apply(HookEnvelope(payload: p, expectsReply: false))
        #expect(NotchActivityState.make(sessions: [st2.sessions["s1"]!], quota: nil).prompt?.sessionScope == nil)
    }

    @Test func brokerSendsAllowWithTheRule() throws {
        var b = PermissionBroker(); let sink = Sink()
        b.register(sink, for: "s1")
        let rule = try #require(PendingPermission.sessionRule(from: suggestion(), tool: "Bash")).rule
        let first = b.answerAllowForSession("s1", rule: rule)
        #expect(first)
        #expect(sink.sent == [HookReply(decision: .allow, updatedPermissions: [rule])])
        let second = b.answerAllowForSession("s1", rule: rule)
        #expect(!second, "no live hook: nothing delivered")
    }

    @Test func stateStaysWithinBudgetWithLongScopes() {
        var st = SessionStore()
        for i in 0..<10 {
            _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = "go" })
            _ = st.apply(
                ev("PermissionRequest", sid: "s\(i)", expectsReply: true) {
                    $0.toolName = "Bash"; $0.toolInput = .object(["command": .string(String(repeating: "x", count: 400))])
                    $0.permissionSuggestions = suggestion(content: String(repeating: "y", count: 400))
                })
        }
        let s = NotchActivityState.make(sessions: st.active, quota: nil)
        #expect(s.prompt?.sessionScope != nil && s.encodedSize < NotchActivityState.byteBudget)
    }
}
