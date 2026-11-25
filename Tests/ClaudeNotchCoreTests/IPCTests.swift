import Darwin
import Foundation
import Testing

@testable import ClaudeNotchCore

private func tmpSocket() -> String { "/tmp/cn-ipc-\(getpid())-\(Int.random(in: 0..<999_999)).sock" }

/// A plain blocking client connection, so tests can misbehave in ways the real client never would.
private func rawConnect(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    // Writing to a peer that already closed must fail with EPIPE, not kill the test process with SIGPIPE.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    guard let (addr, len) = makeAddr(path) else { return -1 }
    var a = addr
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    return fd
}

private func event(_ name: String, sid: String = "s", prompt: String? = nil) -> HookEnvelope {
    var p = HookPayload(sessionId: sid, hookEventName: name)
    p.prompt = prompt
    return HookEnvelope(payload: p)
}

private func openFDCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }

/// Polls until `cond` holds or `timeout` elapses; returns elapsed seconds, or nil on timeout.
private func wait(timeout: TimeInterval = 3, _ cond: () -> Bool) -> TimeInterval? {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < timeout {
        if cond() { return Date().timeIntervalSince(t0) }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return nil
}

@Suite(.serialized) struct IPCTests {
    @Test func staleSilentConnectionOnlyDelaysLaterEventsBriefly() throws {
        let path = tmpSocket()
        let got = Box<[String]>([])
        let server = NotchServer(path: path) { env, _ in got.mutate { $0.append(env.payload.hookEventName ?? "?") } }
        try server.start()
        defer { server.stop() }
        let stale = rawConnect(path)  // connects, sends nothing, stays open
        defer { close(stale) }
        let t0 = Date()
        _ = NotchClient.send(event("Stop"), path: path)
        let took = wait { got.value == ["Stop"] }
        #expect(took != nil && Date().timeIntervalSince(t0) < 0.8)  // bounded by the read budget, not unbounded
    }

    @Test func trickleWriterCannotStarveLaterEvents() throws {
        let path = tmpSocket()
        let got = Box<[String]>([])
        let server = NotchServer(path: path) { env, _ in got.mutate { $0.append(env.payload.hookEventName ?? "?") } }
        try server.start()
        defer { server.stop() }
        let slow = rawConnect(path)
        let stop = Box<Bool>(false)
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {  // one byte every 80 ms, never a newline
            while !stop.value { var b: UInt8 = 0x20; _ = write(slow, &b, 1); Thread.sleep(forTimeInterval: 0.08) }
            writerDone.signal()
        }
        defer {
            stop.mutate { $0 = true }
            writerDone.wait()  // the writer must be finished before the fd is closed (and its number reused)
            close(slow)
        }
        let t0 = Date()
        _ = NotchClient.send(event("Stop"), path: path)
        #expect(wait { got.value.contains("Stop") } != nil)
        #expect(Date().timeIntervalSince(t0) < 0.8)
    }

    @Test func clientGivesUpWhenAppAcceptsButNeverReads() throws {
        // A stub that accepts and then ignores the socket: the old client blocked forever in write().
        let path = tmpSocket()
        guard let (addr, len) = makeAddr(path) else { return }
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = addr
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, len) } }
        listen(lfd, 4)
        defer { close(lfd); unlink(path) }
        let accepted = Box<Int32>(-1)
        DispatchQueue.global().async { accepted.mutate { $0 = accept(lfd, nil, nil) } }  // accept, never read
        defer { if accepted.value >= 0 { close(accepted.value) } }

        let t0 = Date()
        let reply = NotchClient.send(event("UserPromptSubmit", prompt: String(repeating: "x", count: 4_000_000)), path: path)
        #expect(reply == nil)
        #expect(Date().timeIntervalSince(t0) < 2.5)  // bounded by NotchClient.sendBudget
    }

    @Test func largeMessagesAreDeliveredNotDropped() throws {
        let path = tmpSocket()
        let got = Box<Int>(0)
        let server = NotchServer(path: path) { env, _ in got.mutate { $0 = env.payload.prompt?.count ?? 0 } }
        try server.start()
        defer { server.stop() }
        let t0 = Date()
        _ = NotchClient.send(event("UserPromptSubmit", prompt: String(repeating: "y", count: 5_000_000)), path: path)
        #expect(wait(timeout: 5) { got.value == 5_000_000 } != nil)  // above the old 4 MB cap
        #expect(Date().timeIntervalSince(t0) < 3)  // chunked reads, not one byte at a time
    }

    @Test func eventsAreDeliveredInSendOrder() throws {
        let path = tmpSocket()
        let got = Box<[Int]>([])
        let server = NotchServer(path: path) { env, _ in got.mutate { $0.append(Int(env.payload.prompt ?? "-1") ?? -1) } }
        try server.start()
        defer { server.stop() }
        for i in 0..<300 { _ = NotchClient.send(event("PostToolUse", prompt: String(i)), path: path) }
        #expect(wait(timeout: 5) { got.value.count == 300 } != nil)
        #expect(got.value == Array(0..<300))
    }

    @Test func secondServerCannotStealALiveSocket() throws {
        let path = tmpSocket()
        let got = Box<Int>(0)
        let first = NotchServer(path: path) { _, _ in got.mutate { $0 += 1 } }
        try first.start()
        let second = NotchServer(path: path) { _, _ in }
        #expect(throws: POSIXError.self) { try second.start() }
        _ = NotchClient.send(event("Stop"), path: path)
        #expect(wait { got.value == 1 } != nil)  // the first instance still owns the socket
        first.stop()
        try second.start()  // once the first is gone, starting works
        second.stop()
    }

    @Test func overlongSocketPathFailsCleanly() {
        let long = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        #expect(throws: POSIXError.self) { try NotchServer(path: long) { _, _ in }.start() }
        #expect(NotchClient.send(event("Stop"), path: long) == nil)  // no crash, no hang
    }

    @Test func replyIsDeliveredOnceAndLaterAnswersAreHarmless() throws {
        let path = tmpSocket()
        let handle = Box<ReplyHandle?>(nil)
        let server = NotchServer(path: path) { _, h in handle.mutate { $0 = h } }
        try server.start()
        defer { server.stop() }
        var env = event("PermissionRequest")
        env.expectsReply = true
        let reply = Box<HookReply?>(nil)
        DispatchQueue.global().async {
            let r = NotchClient.send(env, replyTimeoutSec: 3, path: path); reply.mutate { $0 = r }
        }
        #expect(wait { handle.value != nil } != nil)
        handle.value?.send(HookReply(decision: .allow))
        handle.value?.send(HookReply(decision: .deny))  // second answer must not change the outcome
        #expect(wait { reply.value != nil } != nil)
        #expect(reply.value == HookReply(decision: .allow))
        #expect(handle.value?.isOpen == false)
    }

    @Test func hookDisappearingFiresOnCloseExactlyOnceAndLaterSendDoesNotCrash() throws {
        let path = tmpSocket()
        let closes = Box<Int>(0)
        let handle = Box<ReplyHandle?>(nil)
        let server = NotchServer(path: path) { _, h in
            h?.onClose = { closes.mutate { $0 += 1 } }
            handle.mutate { $0 = h }
        }
        try server.start()
        defer { server.stop() }
        var env = event("PermissionRequest")
        env.expectsReply = true
        let fd = rawConnect(path)
        let line = try env.encodedLine()
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        #expect(wait { handle.value != nil } != nil)
        Thread.sleep(forTimeInterval: 0.15)
        close(fd)  // the hook is killed (timeout / Ctrl-C)
        #expect(wait { closes.value == 1 } != nil)
        handle.value?.send(HookReply(decision: .allow))  // answering a dead hook: harmless
        Thread.sleep(forTimeInterval: 0.2)
        #expect(closes.value == 1)
    }

    @Test func answeredAndAbandonedRequestsDoNotLeakDescriptors() throws {
        let path = tmpSocket()
        let handles = Box<[ReplyHandle]>([])
        let server = NotchServer(path: path) { _, h in if let h { handles.mutate { $0.append(h) } } }
        try server.start()
        defer { server.stop() }
        var env = event("PermissionRequest")
        env.expectsReply = true
        let before = openFDCount()
        for i in 0..<60 {
            let fd = rawConnect(path)
            let line = try env.encodedLine()
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
            #expect(wait { handles.value.count == i + 1 } != nil)
            if i % 2 == 0 { handles.value[i].send(HookReply(decision: .allow)) }  // answered
            close(fd)  // and/or abandoned by the hook
        }
        handles.mutate { $0.removeAll() }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(openFDCount() <= before + 4)
    }
}
