import Foundation
import Testing

@testable import NotchbotCore

private final class FakeSink: ReplySink, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [HookReply] = []
    var sent: [HookReply] { lock.lock(); defer { lock.unlock() }; return _sent }
    func send(_ reply: HookReply) { lock.lock(); _sent.append(reply); lock.unlock() }
}

@Suite struct PermissionBrokerTests {
    func pending(tool: String = "t1", agent: String? = nil) -> PendingPermission {
        PendingPermission(
            id: UUID(), toolName: "Bash", summary: "Bash", message: nil, agentType: nil, agentId: agent,
            toolUseId: tool, canAnswer: true, since: Date())
    }
    func payload(_ sid: String = "s1", tool: String? = nil) -> HookPayload {
        var p = HookPayload(sessionId: sid); p.toolUseId = tool; return p
    }

    @Test func unrelatedEventsDoNotReleaseTheHeldHook() {
        var b = PermissionBroker(); let sink = FakeSink()
        b.register(sink, for: "s1")
        for ev in ["Notification", "PreToolUse", "SubagentStart", "SubagentStop", "PreCompact"] {
            b.handle(event: ev, payload: payload(), pending: pending())
        }
        b.handle(event: "PostToolUse", payload: payload(tool: "other"), pending: pending(tool: "t1"))  // different tool
        #expect(b.hasLiveRequest(for: "s1") && sink.sent.isEmpty)
    }

    @Test func settlingEventsReleaseWithAskFallback() {
        for ev in ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"] {
            var b = PermissionBroker(); let sink = FakeSink()
            b.register(sink, for: "s1")
            b.handle(event: ev, payload: payload(), pending: pending())
            #expect(!b.hasLiveRequest(for: "s1") && sink.sent == [HookReply(decision: .ask)], "\(ev)")
        }
        var b = PermissionBroker(); let sink = FakeSink()
        b.register(sink, for: "s1")
        b.handle(event: "PostToolUse", payload: payload(tool: "t1"), pending: pending(tool: "t1"))  // the request's own tool ran
        #expect(sink.sent == [HookReply(decision: .ask)])
    }

    @Test func answerWithoutLiveHookIsANoOp() {
        var b = PermissionBroker()
        #expect(b.answer("s1", .allow) == false)
        let sink = FakeSink(); b.register(sink, for: "s1")
        #expect(b.answer("s1", .deny, reason: "no") == true)
        #expect(b.answer("s1", .allow) == false)  // second answer: nothing to send to
        #expect(sink.sent == [HookReply(decision: .deny, reason: "no")])
    }

    @Test func newRequestFallsPreviousHeldHookBackToTerminal() {
        var b = PermissionBroker(); let first = FakeSink(), second = FakeSink()
        b.register(first, for: "s1"); b.register(second, for: "s1")
        #expect(first.sent == [HookReply(decision: .ask)] && second.sent.isEmpty)
        #expect(b.hasLiveRequest(for: "s1"))
    }

    @Test func peerClosedForgetsOnlyThatHook() {
        var b = PermissionBroker(); let old = FakeSink(), current = FakeSink()
        b.register(current, for: "s1")
        b.peerClosed("s1", sink: old)  // stale close notification
        #expect(b.hasLiveRequest(for: "s1"))
        b.peerClosed("s1", sink: current)
        #expect(!b.hasLiveRequest(for: "s1") && current.sent.isEmpty)
    }

    @Test func heldHookWithNoRecordedRequestIsNotStranded() {
        var b = PermissionBroker(); let sink = FakeSink()
        b.register(sink, for: "s1")
        b.handle(event: "Notification", payload: payload(), pending: nil)
        #expect(sink.sent == [HookReply(decision: .ask)])
    }
}
