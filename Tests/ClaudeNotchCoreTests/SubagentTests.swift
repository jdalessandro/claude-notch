import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct Subagents {
    @Test func subagentEventsDontClobberParentAndTrackLifecycle() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "audit auth" })
        s.apply(
            ev("PreToolUse", t: 1) {
                $0.toolName = "Task"; $0.toolInput = .object(["description": .string("Map the auth flow")])
            })
        s.apply(
            ev("SubagentStart", t: 2) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(
            ev("PreToolUse", t: 3) {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("login")])
            })
        let sess = s.sessions["s1"]!
        #expect(sess.currentTool == "Task")  // parent untouched by subagent tool call
        #expect(sess.subagents["a1"]?.label == "Map the auth flow")
        #expect(sess.subagents["a1"]?.currentDetail == "Grep: login")
        #expect(sess.runningSubagents == 1)
        s.apply(
            ev("SubagentStop", t: 9) {
                $0.agentId = "a1"; $0.lastAssistantMessage = "Found 3 entry points"
            })
        #expect(s.sessions["s1"]?.subagents["a1"]?.status == .done)
        #expect(s.sessions["s1"]?.subagents["a1"]?.lastMessage == "Found 3 entry points")
        // New prompt clears the previous turn's subagents.
        s.apply(ev("UserPromptSubmit", t: 20) { $0.prompt = "next" })
        #expect(s.sessions["s1"]?.subagents.isEmpty == true)
    }

    @Test func subagentPermissionSurfacesOnSessionAndStopClosesRunning() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart") {
                $0.agentId = "a1"; $0.agentType = "general-purpose"
            })
        let e = s.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.agentId = "a1"; $0.agentType = "general-purpose"; $0.toolName = "Bash"
            })
        #expect(e == .notify(sessionId: "s1", kind: .permission))
        #expect(s.sessions["s1"]?.pending?.agentType == "general-purpose")
        s.apply(ev("Stop", t: 5))
        #expect(s.sessions["s1"]?.runningSubagents == 0)
    }

    @Test func subagentFinishingItsToolClearsItsPendingRequest() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart") {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(
            ev("PermissionRequest", t: 1, expectsReply: true) {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Bash"; $0.toolUseId = "t1"
            })
        #expect(s.sessions["s1"]?.status == .needsPermission)
        // The user answered in the terminal; the subagent's tool then completes.
        s.apply(
            ev("PostToolUse", t: 2) {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Bash"; $0.toolUseId = "t1"
            })
        #expect(s.sessions["s1"]?.pending == nil && s.sessions["s1"]?.status == .working)
    }

    @Test func subagentStopBeforeStartDoesNotRegress() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStop") {
                $0.agentId = "a1"; $0.lastAssistantMessage = "done"
            })
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        #expect(s.sessions["s1"]?.subagents["a1"]?.status == .done)  // a late Start must not revive it
    }
}
