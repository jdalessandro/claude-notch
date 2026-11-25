import Foundation

/// Anything that can deliver a decision back to a blocked hook.
public protocol ReplySink: AnyObject, Sendable {
    func send(_ reply: HookReply)
}

extension ReplyHandle: ReplySink {}

/// Owns the blocked-hook handles for pending permission requests, one per session.
///
/// Rules (each one is a bug the review found in the earlier inline version):
/// - A new request for a session hands the previous held hook `.ask` (fall back to the terminal) first.
/// - A handle is released only by an event that really settles the request (`PendingPermission.isResolved`),
///   never by unrelated traffic such as the `Notification` that follows a request.
/// - `answer` is a no-op unless a live handle exists, so the UI can never claim "allowed" for a request the
///   hook is no longer waiting on.
public struct PermissionBroker {
    private var sinks: [String: any ReplySink] = [:]
    public init() {}

    public func hasLiveRequest(for session: String) -> Bool { sinks[session] != nil }

    public mutating func register(_ sink: any ReplySink, for session: String) {
        sinks.removeValue(forKey: session)?.send(HookReply(decision: .ask))
        sinks[session] = sink
    }

    /// Falls the held hook back to the terminal prompt. Returns whether one was held.
    @discardableResult
    public mutating func release(_ session: String) -> Bool {
        guard let s = sinks.removeValue(forKey: session) else { return false }
        s.send(HookReply(decision: .ask))
        return true
    }

    /// Delivers the user's decision. Returns false (and does nothing) when no live hook is waiting.
    @discardableResult
    public mutating func answer(_ session: String, _ decision: PermissionDecision, reason: String? = nil) -> Bool {
        guard let s = sinks.removeValue(forKey: session) else { return false }
        s.send(HookReply(decision: decision, reason: reason))
        return true
    }

    /// The hook went away on its own (timeout, Ctrl-C, answered in the terminal): forget it without replying.
    public mutating func peerClosed(_ session: String, sink: any ReplySink) {
        if let current = sinks[session], current === sink { sinks[session] = nil }
    }

    /// Call before applying an event to the store: releases the held hook if the event settles the request.
    public mutating func handle(event: String, payload: HookPayload, pending: PendingPermission?) {
        guard let sid = payload.sessionId, sinks[sid] != nil else { return }
        guard let pending else { release(sid); return }  // held hook but no request recorded: don't strand it
        if pending.isResolved(by: event, payload: payload) { release(sid) }
    }
}
