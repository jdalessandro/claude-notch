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

    @Test func subagentPermissionSurfacesOnTheSession() {
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

    @Test func backgroundSubagentsKeepTheSessionWorkingAfterTheMainTurnStops() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "migrate CI" })
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "a2"; $0.agentType = "general-purpose"
            })
        let stop = s.apply(ev("Stop", t: 5) { $0.lastAssistantMessage = "Kicked off two agents" })
        #expect(stop == .none)  // not finished: no premature notification
        #expect(s.sessions["s1"]?.status == .working && s.sessions["s1"]?.runningSubagents == 2)  // not "Idle"
        #expect(s.sessions["s1"]?.mainTurnEnded == true && s.sessions["s1"]?.unseen == false)
        // Their later events still update them.
        s.apply(
            ev("PreToolUse", t: 6) {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("ci")])
            })
        #expect(s.sessions["s1"]?.subagents["a1"]?.currentDetail == "Grep: ci" && s.sessions["s1"]?.status == .working)
        // One finishing is not enough ...
        #expect(s.apply(ev("SubagentStop", t: 7) { $0.agentId = "a1" }) == .none)
        #expect(s.sessions["s1"]?.status == .working)
        // ... the last one finishes the turn: now it is done, unseen, and notifies exactly once.
        let done = s.apply(
            ev("SubagentStop", t: 9) {
                $0.agentId = "a2"; $0.lastAssistantMessage = "ok"
            })
        #expect(done == .notify(sessionId: "s1", kind: .finished))
        #expect(s.sessions["s1"]?.status == .done && s.sessions["s1"]?.unseen == true && s.sessions["s1"]?.workingSince == nil)
        #expect(s.sessions["s1"]?.lastMessage == "Kicked off two agents")
    }

    @Test func aStopWithNoSubagentsStillFinishesImmediately() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "x" })
        #expect(s.apply(ev("Stop", t: 3)) == .notify(sessionId: "s1", kind: .finished))
        #expect(s.sessions["s1"]?.status == .done)
    }

    @Test func aSilentSubagentIsEventuallyTreatedAsFinished() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "x" })
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(ev("Stop", t: 2))
        #expect(s.prune(now: Date(timeIntervalSince1970: 1000 + 600), subagentStale: 900).isEmpty)  // still recent
        let effects = s.prune(now: Date(timeIntervalSince1970: 1000 + 2000), subagentStale: 900)  // crashed / never stopped
        #expect(effects == [.notify(sessionId: "s1", kind: .finished)])
        #expect(s.sessions["s1"]?.status == .done && s.sessions["s1"]?.runningSubagents == 0)
    }

    @Test func aLiveSubagentIsNotMistakenForStale() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(ev("Stop", t: 2))
        s.apply(
            ev("PreToolUse", t: 1900) {
                $0.agentId = "a1"; $0.agentType = "Explore"; $0.toolName = "Read"
            })  // heard from recently
        #expect(s.prune(now: Date(timeIntervalSince1970: 1000 + 2000), subagentStale: 900).isEmpty)
        #expect(s.sessions["s1"]?.status == .working)
    }

    @Test func aNewPromptResetsTheTurnAndTheTreeIsRankedRunningFirst() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart", t: 1) {
                $0.agentId = "old"; $0.agentType = "Explore"
            })
        s.apply(ev("SubagentStop", t: 2) { $0.agentId = "old" })
        s.apply(
            ev("SubagentStart", t: 3) {
                $0.agentId = "new"; $0.agentType = "general-purpose"
            })
        s.apply(
            ev("SubagentStart", t: 4) {
                $0.agentId = "newer"; $0.agentType = "Plan"
            })
        #expect(s.sessions["s1"]?.rankedSubagents.map(\.id) == ["new", "newer", "old"])  // running first (oldest first), then finished
        s.apply(ev("Stop", t: 5))
        s.apply(ev("UserPromptSubmit", t: 6) { $0.prompt = "again" })
        #expect(s.sessions["s1"]?.mainTurnEnded == false && s.sessions["s1"]?.subagents.isEmpty == true)
    }

    @Test func endingTheSessionSettlesRunningSubagents() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart") {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(ev("SessionEnd", t: 5))
        #expect(s.sessions["s1"]?.runningSubagents == 0 && s.sessions["s1"]?.status == .ended)
    }

    @Test func subagentsThatStartAfterTheMainTurnStoppedWakeTheSession() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "kick off background work" })
        #expect(s.apply(ev("Stop", t: 2) { $0.lastAssistantMessage = "Started it." }) == .notify(sessionId: "s1", kind: .finished))
        #expect(s.sessions["s1"]?.status == .done)
        // The order seen with background tasks: the main turn is already over when the subagents begin.
        s.apply(
            ev("SubagentStart", t: 5) {
                $0.agentId = "bg1"; $0.agentType = "general-purpose"
            })
        #expect(s.sessions["s1"]?.status == .working && s.sessions["s1"]?.runningSubagents == 1)  // not Idle
        s.apply(
            ev("SubagentStart", t: 6) {
                $0.agentId = "bg2"; $0.agentType = "Explore"
            })
        s.apply(
            ev("PreToolUse", t: 7) {
                $0.agentId = "bg2"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("x")])
            })
        #expect(s.sessions["s1"]?.status == .working)
        #expect(s.sessions["s1"]?.workingSince != nil && s.sessions["s1"]?.unseen == false)
        // They finish: the session goes idle again and the result is flagged for review, once.
        #expect(s.apply(ev("SubagentStop", t: 20) { $0.agentId = "bg1" }) == .none)
        #expect(s.apply(ev("SubagentStop", t: 21) { $0.agentId = "bg2" }) == .notify(sessionId: "s1", kind: .finished))
        #expect(s.sessions["s1"]?.status == .done && s.sessions["s1"]?.unseen == true)
    }

    @Test func aSubagentsFirstEventAloneIsEnoughToNoticeItWithoutSubagentStart() {
        // Hooks installed before SubagentStart existed: the first event carrying agent_id must do the same job.
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "x" })
        s.apply(ev("Stop", t: 2))
        s.apply(
            ev("PreToolUse", t: 4) {
                $0.agentId = "late"; $0.agentType = "Explore"; $0.toolName = "Read"
            })
        #expect(s.sessions["s1"]?.status == .working && s.sessions["s1"]?.runningSubagents == 1)
    }

    @Test func staleOrUnrelatedEventsDoNotWakeAnIdleSession() {
        var s = SessionStore()
        s.apply(
            ev("SubagentStart") {
                $0.agentId = "a1"; $0.agentType = "Explore"
            })
        s.apply(ev("SubagentStop", t: 2) { $0.agentId = "a1" })
        s.apply(ev("UserPromptSubmit", t: 3) { $0.prompt = "x" }); s.apply(ev("Stop", t: 4))
        s.apply(
            ev("SubagentStart", t: 5) {
                $0.agentId = "a2"; $0.agentType = "Explore"
            })
        s.apply(ev("SubagentStop", t: 6) { $0.agentId = "a2" })
        #expect(s.sessions["s1"]?.status == .done)
        // A straggler tool event from a subagent that already stopped must not revive anything.
        s.apply(
            ev("PostToolUse", t: 7) {
                $0.agentId = "a2"; $0.agentType = "Explore"; $0.toolName = "Read"
            })
        #expect(s.sessions["s1"]?.status == .done)
        // An ended or waiting session is never woken.
        var e = SessionStore()
        e.apply(ev("SessionEnd"));
        e.apply(
            ev("PreToolUse", t: 1) {
                $0.agentId = "z"; $0.agentType = "Explore"; $0.toolName = "Read"
            })
        #expect(e.sessions["s1"]?.status == .ended)
        var w = SessionStore()
        w.apply(ev("PermissionRequest", expectsReply: true) { $0.toolName = "Bash" })
        w.apply(
            ev("PreToolUse", t: 1) {
                $0.agentId = "z"; $0.agentType = "Explore"; $0.toolName = "Read"
            })
        #expect(w.sessions["s1"]?.status == .needsPermission)
    }

    @Test func eachSessionSummarisesItsOwnSubagents() {
        var s = SessionStore()
        #expect(s.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "x" }) == .none)
        #expect(s.sessions["a"]?.subagentSummary == nil && s.sessions["a"]?.subagentBadgeCount == 0)
        s.apply(
            ev("SubagentStart", sid: "a", t: 1) {
                $0.agentId = "1"; $0.agentType = "Explore"
            })
        s.apply(
            ev("SubagentStart", sid: "a", t: 1) {
                $0.agentId = "2"; $0.agentType = "Plan"
            })
        s.apply(
            ev("SubagentStart", sid: "a", t: 1) {
                $0.agentId = "3"; $0.agentType = "Explore"
            })
        #expect(s.sessions["a"]?.subagentSummary == "3 running" && s.sessions["a"]?.subagentBadgeCount == 3)
        s.apply(ev("SubagentStop", sid: "a", t: 5) { $0.agentId = "1" })
        #expect(s.sessions["a"]?.subagentSummary == "2 running · 1 done" && s.sessions["a"]?.subagentBadgeCount == 2)
        s.apply(ev("SubagentStop", sid: "a", t: 6) { $0.agentId = "2" })
        s.apply(ev("SubagentStop", sid: "a", t: 7) { $0.agentId = "3" })
        #expect(s.sessions["a"]?.subagentSummary == "3 done" && s.sessions["a"]?.subagentBadgeCount == 3)
        // Another session's subagents are not mixed in.
        s.apply(
            ev("SubagentStart", sid: "b") {
                $0.agentId = "x"; $0.agentType = "Explore"
            })
        #expect(s.sessions["a"]?.subagentSummary == "3 done" && s.sessions["b"]?.subagentSummary == "1 running")
    }
}
