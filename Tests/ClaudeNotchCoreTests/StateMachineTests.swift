import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct StateMachine {
    @Test func promptToolStopCycle() {
        var s = SessionStore()
        s.apply(ev("SessionStart"))
        s.apply(ev("UserPromptSubmit", t: 1) { $0.prompt = "fix bug" })
        #expect(s.sessions["s1"]?.status == .working)
        s.apply(
            ev("PreToolUse", t: 2) {
                $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("swift build")])
            })
        #expect(s.sessions["s1"]?.currentToolDetail == "Bash: swift build")
        s.apply(ev("PostToolUse", t: 3))
        let eff = s.apply(ev("Stop", t: 11))
        #expect(eff == .notify(sessionId: "s1", kind: .finished))
        #expect(s.sessions["s1"]?.status == .done)
        #expect(s.sessions["s1"]?.unseen == true)
        #expect(s.sessions["s1"]?.lastTurnDuration == 10)
    }

    @Test func answerableRequestSurvivesParallelToolsAndResolvesOnMatchingPostToolUse() {
        var s = SessionStore()
        let eff = s.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.toolName = "Bash"; $0.toolUseId = "t1"; $0.toolInput = .object(["command": .string("rm -rf x")])
            })
        #expect(eff == .notify(sessionId: "s1", kind: .permission))
        #expect(s.sessions["s1"]?.pending?.canAnswer == true)
        #expect(s.attentionCount == 1)
        // Another tool starting in parallel must not make a held approval vanish.
        s.apply(
            ev("PreToolUse", t: 5) {
                $0.toolName = "Read"; $0.toolUseId = "t2"
            })
        #expect(s.sessions["s1"]?.pending != nil && s.sessions["s1"]?.status == .needsPermission)
        // A different tool finishing doesn't settle it either.
        s.apply(
            ev("PostToolUse", t: 6) {
                $0.toolName = "Read"; $0.toolUseId = "t2"
            })
        #expect(s.sessions["s1"]?.pending != nil)
        // The tool the request was for finishing does.
        s.apply(
            ev("PostToolUse", t: 7) {
                $0.toolName = "Bash"; $0.toolUseId = "t1"
            })
        #expect(s.sessions["s1"]?.pending == nil && s.sessions["s1"]?.status == .working)
    }

    @Test func observeOnlyRequestClearsWhenNextToolStarts() {
        var s = SessionStore()
        s.apply(ev("PermissionRequest", expectsReply: false) { $0.toolName = "Bash" })
        s.apply(ev("PreToolUse", t: 5) { $0.toolName = "Bash" })
        #expect(s.sessions["s1"]?.pending == nil && s.sessions["s1"]?.status == .working)
    }

    @Test func notificationBeforeOrAfterRequestNotifiesOnce() {
        var s = SessionStore()
        let first = s.apply(ev("Notification") { $0.notificationType = "permission_prompt" })
        let second = s.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.toolName = "Bash"; $0.toolUseId = "t1"
            })
        #expect(first == .notify(sessionId: "s1", kind: .permission) && second == .none)
        // Request first, then the Notification Claude Code fires right after: still one notification, request intact.
        var u = SessionStore()
        let a = u.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.toolName = "Bash"; $0.toolUseId = "t1"
            })
        let b = u.apply(ev("Notification", t: 1) { $0.notificationType = "permission_prompt" })
        #expect(a == .notify(sessionId: "s1", kind: .permission) && b == .none)
        #expect(u.sessions["s1"]?.pending?.canAnswer == true)
        // A genuinely new request (different tool use) notifies again.
        let c = u.apply(
            ev("PermissionRequest", t: 2, expectsReply: true) {
                $0.toolName = "Write"; $0.toolUseId = "t9"
            })
        #expect(c == .notify(sessionId: "s1", kind: .permission))
    }

    @Test func compactingEndsWithToolActivityOrPostCompact() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "x" })
        s.apply(ev("PreCompact", t: 1))
        #expect(s.sessions["s1"]?.status == .compacting)
        s.apply(ev("PreToolUse", t: 2) { $0.toolName = "Bash" })
        #expect(s.sessions["s1"]?.status == .working)  // no longer stuck on "Compacting"
        s.apply(ev("PreCompact", t: 3)); s.apply(ev("PostCompact", t: 4))
        #expect(s.sessions["s1"]?.status == .working)
    }

    @Test func sessionStartCompactMidTurnKeepsWorking() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit") { $0.prompt = "x" })
        s.apply(ev("SessionStart", t: 1) { $0.source = "compact" })
        #expect(s.sessions["s1"]?.status == .working && s.sessions["s1"]?.workingSince != nil)
    }

    @Test func lateNotificationDoesNotResurrectEndedSession() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit")); s.apply(ev("SessionEnd", t: 1))
        let e = s.apply(ev("Notification", t: 2) { $0.notificationType = "idle_prompt" })
        #expect(e == .none && s.sessions["s1"]?.status == .ended)
    }

    @Test func pruneKeepsSessionHoldingALiveApproval() {
        var s = SessionStore()
        s.apply(ev("PermissionRequest", expectsReply: true) { $0.toolName = "Bash" })
        s.prune(now: Date(timeIntervalSince1970: 1000 + 600), endedTTL: 120, idleTTL: 300)  // idle TTL passed, hook still waiting
        #expect(s.sessions["s1"] != nil)
    }

    @Test func notificationTypesAndDedup() {
        var s = SessionStore()
        #expect(
            s.apply(
                ev("Notification") {
                    $0.notificationType = "permission_prompt"; $0.message = "Claude needs permission"
                }) != .none)
        // A second permission notification while already blocked must not re-notify.
        #expect(s.apply(ev("Notification", t: 1) { $0.notificationType = "permission_prompt" }) == .none)
        var s2 = SessionStore()
        #expect(s2.apply(ev("Notification") { $0.notificationType = "idle_prompt" }) == .notify(sessionId: "s1", kind: .input))
        #expect(s2.sessions["s1"]?.status == .needsInput)
        // Legacy text-only notification.
        var s3 = SessionStore()
        #expect(
            s3.apply(ev("Notification") { $0.message = "Claude needs your permission to use Bash" })
                == .notify(sessionId: "s1", kind: .permission))
    }

    @Test func orderingAndPruning() {
        var s = SessionStore()
        s.apply(ev("UserPromptSubmit", sid: "a", t: 0))
        s.apply(ev("PermissionRequest", sid: "b", t: -10))
        s.apply(ev("SessionEnd", sid: "c", t: 5))
        #expect(s.ordered.map(\.id) == ["b", "a", "c"])
        #expect(s.active.count == 2)
        s.prune(now: Date(timeIntervalSince1970: 1000 + 500))
        #expect(s.sessions["c"] == nil && s.sessions["a"] != nil)
    }

    @Test func failureAndSeen() {
        var s = SessionStore()
        #expect(s.apply(ev("StopFailure") { $0.message = "rate limited" }) == .notify(sessionId: "s1", kind: .failed))
        #expect(s.sessions["s1"]?.attentionMessage == "rate limited")
        s.markSeen("s1")
        #expect(s.attentionCount == 0)
    }

    @Test func summaries() {
        #expect(SessionStore.summarize(tool: "Edit", input: .object(["file_path": .string("/a/b/File.swift")])) == "Edit: File.swift")
        #expect(SessionStore.summarize(tool: "mcp__x__y", input: nil) == "mcp__x__y")
    }
}
