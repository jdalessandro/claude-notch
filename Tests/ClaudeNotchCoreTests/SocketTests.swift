import Foundation
import Testing

@testable import ClaudeNotchCore

@Suite struct Socket {
    @Test func fireAndForgetAndReply() async throws {
        let path = "/tmp/cn-\(getpid())-\(Int.random(in: 0..<9999)).sock"
        let got = Box<[String]>([])
        let server = NotchServer(path: path) { env, reply in
            got.mutate { $0.append(env.payload.hookEventName ?? "?") }
            reply?.send(HookReply(decision: .deny, reason: "nope"))
        }
        try server.start(); defer { server.stop() }

        #expect(NotchClient.send(HookEnvelope(payload: HookPayload(sessionId: "x", hookEventName: "Stop")), path: path) == nil)
        let r = NotchClient.send(
            HookEnvelope(payload: HookPayload(sessionId: "x", hookEventName: "PermissionRequest"), expectsReply: true),
            replyTimeoutSec: 3, path: path)
        #expect(r == HookReply(decision: .deny, reason: "nope"))
        // Poll instead of sleeping a fixed time: delivery is asynchronous and CI runners are slow.
        let deadline = Date().addingTimeInterval(3)
        while got.value.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got.value == ["Stop", "PermissionRequest"])
        // No server => silent nil, no crash.
        #expect(NotchClient.send(HookEnvelope(payload: HookPayload(sessionId: "x")), path: "/tmp/nonexistent.sock") == nil)
    }
}
