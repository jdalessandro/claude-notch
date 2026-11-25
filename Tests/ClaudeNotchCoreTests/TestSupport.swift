import Foundation
import Testing

@testable import ClaudeNotchCore

func ev(
    _ name: String, sid: String = "s1", t: TimeInterval = 0, expectsReply: Bool = false,
    _ cfg: (inout HookPayload) -> Void = { _ in }
) -> HookEnvelope {
    var p = HookPayload(sessionId: sid, cwd: "/tmp/proj", hookEventName: name)
    cfg(&p)
    return HookEnvelope(payload: p, receivedAt: Date(timeIntervalSince1970: 1000 + t), expectsReply: expectsReply)
}

final class Box<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.lock(); defer { l.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}
