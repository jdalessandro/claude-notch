import Foundation
import Testing

@testable import ClaudeNotchCore

/// Drives the real `claude-notch-hook` executable the way Claude Code does.
@Suite struct HookBinary {
    static var hookURL: URL {
        // .build/<config>/ClaudeNotchCorePackageTests.xctest/... -> sibling of the products dir
        var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while u.pathComponents.count > 1 {
            let c = u.deletingLastPathComponent().appendingPathComponent("claude-notch-hook")
            if FileManager.default.isExecutableFile(atPath: c.path) { return c }
            u = u.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: ".build/debug/claude-notch-hook")
    }

    func run(stdin: String, args: [String] = [], socket: String) throws -> (out: String, code: Int32) {
        let p = Process(); p.executableURL = Self.hookURL; p.arguments = args
        p.environment = ["CLAUDE_NOTCH_SOCKET": socket, "TERM_PROGRAM": "iTerm.app"]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = Pipe()
        try p.run()
        i.fileHandleForWriting.write(Data(stdin.utf8)); try i.fileHandleForWriting.close()
        p.waitUntilExit()
        return (String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
    }

    @Test func interactivePermissionAllowAndDeny() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.hookURL.path), "build claude-notch-hook first")
        let path = "/tmp/cn-hook-\(getpid()).sock"
        let seen = Box<[HookEnvelope]>([])
        let decision = Box<PermissionDecision>(.allow)
        let server = NotchServer(path: path) { env, reply in
            seen.mutate { $0.append(env) }
            reply?.send(HookReply(decision: decision.value))
        }
        try server.start(); defer { server.stop() }

        let payload =
            #"{"session_id":"abc","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"unknown_future_field":{"x":1}}"#
        var r = try run(stdin: payload, args: ["--interactive"], socket: path)
        let allow = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any]
        let hso = allow["hookSpecificOutput"] as! [String: Any]
        #expect(hso["hookEventName"] as? String == "PermissionRequest")
        #expect((hso["decision"] as! [String: Any])["behavior"] as? String == "allow")
        #expect(r.code == 0)

        decision.mutate { $0 = .deny }
        r = try run(stdin: payload, args: ["--interactive"], socket: path)
        let d =
            ((try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any])["hookSpecificOutput"] as! [String: Any])[
                "decision"] as! [String: Any]
        #expect(d["behavior"] as? String == "deny" && (d["message"] as? String)?.isEmpty == false)

        decision.mutate { $0 = .ask }
        r = try run(stdin: payload, args: ["--interactive"], socket: path)
        #expect(r.out.isEmpty && r.code == 0)  // falls through to the normal terminal prompt

        #expect(seen.value.count == 3)
        #expect(seen.value[0].payload.sessionId == "abc" && seen.value[0].termProgram == "iTerm.app" && seen.value[0].expectsReply)
    }

    @Test func nonInteractiveAndNoAppAreSilent() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.hookURL.path))
        // No server listening: must exit 0 with no output, quickly.
        let t0 = Date()
        let r = try run(stdin: #"{"session_id":"a","hook_event_name":"Stop"}"#, socket: "/tmp/definitely-not-here.sock")
        #expect(r.out.isEmpty && r.code == 0 && Date().timeIntervalSince(t0) < 2)
        // Garbage stdin must never fail the Claude session.
        #expect(try run(stdin: "not json", socket: "/tmp/definitely-not-here.sock").code == 0)
    }

    @Test func statusLineModeForwardsARealisticPayload() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.hookURL.path))
        let path = "/tmp/cn-sl-\(getpid()).sock"
        let seen = Box<[HookEnvelope]>([])
        let server = NotchServer(path: path) { env, _ in seen.mutate { $0.append(env) } }
        try server.start()
        defer { server.stop() }
        // `model` is an object here; this exact shape made the old decoder drop the event silently.
        let payload =
            #"{"session_id":"s1","cwd":"/p","transcript_path":"/t.jsonl","model":{"id":"claude-opus-5-5","display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":93,"resets_at":1795600000},"seven_day":{"used_percentage":14,"resets_at":1796100000},"seven_day_fable":{"used_percentage":0}},"context_window":{"context_window_size":200000,"used_percentage":12}}"#
        let r = try run(stdin: payload, args: ["--statusline"], socket: path)
        #expect(r.out.isEmpty && r.code == 0)  // the status line itself stays empty
        let deadline = Date().addingTimeInterval(10)
        while seen.value.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let env = try #require(seen.value.first)
        #expect(env.payload.hookEventName == "StatusLine" && env.payload.sessionId == "s1")
        let q = try #require(QuotaState.parse(env.payload.rateLimits))
        #expect(q.windows.map(\.title) == ["5-hour limit", "Weekly · all models", "Weekly · Fable"])
        #expect(q.fiveHour?.usedPercent == 93)
    }

    @Test func hugePayloadsAreTruncatedBeforeSending() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.hookURL.path))
        let path = "/tmp/cn-big-\(getpid()).sock"
        let seen = Box<[HookEnvelope]>([])
        let server = NotchServer(path: path) { env, _ in seen.mutate { $0.append(env) } }
        try server.start()
        defer { server.stop() }
        let big = String(repeating: "z", count: 400_000)
        let r = try run(stdin: #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":""# + big + #""}"#, socket: path)
        #expect(r.code == 0)
        let deadline = Date().addingTimeInterval(10)
        while seen.value.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let n = seen.value.first?.payload.prompt?.count ?? -1
        #expect(n > 0 && n <= 4_001)
    }
}
