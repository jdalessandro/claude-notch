import Foundation
import NotchbotCore

// notchbot-hook: invoked by Claude Code for each hook event.
// Reads the event JSON on stdin, forwards it to the Notchbot app over a Unix socket, and exits 0.
// Design rule: this process must NEVER slow down or break a Claude session. If the app is not
// running, it silently does nothing.
//
//   --interactive   (PermissionRequest only) block until the notch answers Allow/Deny.
//   --install / --uninstall / --status   manage ~/.claude/settings.json (see README).

let args = CommandLine.arguments.dropFirst()
// The real path of this executable (argv[0] may be a bare name when launched through PATH).
let selfPath = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.path

func printResult(_ r: HookInstaller.Result, verb: String) {
    print("\(verb): \((r.added + r.removed).joined(separator: ", "))")
    if let b = r.backup { print("backup: \(b.path)") }
}

if args.contains("--install") || args.contains("--uninstall") || args.contains("--status") {
    do {
        if args.contains("--install") {
            printResult(
                try HookInstaller.install(hookPath: selfPath, interactivePermissions: args.contains("--interactive")), verb: "installed")
        } else if args.contains("--uninstall") {
            printResult(try HookInstaller.uninstall(), verb: "removed")
        } else {
            print(HookInstaller.isInstalled() ? "installed" : "not installed")
        }
    } catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard var payload = try? JSONDecoder().decode(HookPayload.self, from: input) else { exit(0) }
// Cap free text so one giant prompt or file write can't make the event huge (and slow to deliver).
payload = payload.truncated()

// --statusline: Claude Code pipes its status-line JSON here (rate limits, exact context window).
// We forward it to the app and print nothing, so the status line stays empty.
if args.contains("--statusline") {
    payload.hookEventName = "StatusLine"
    _ = NotchClient.send(HookEnvelope(payload: payload, pid: getppid()))
    exit(0)
}

let interactive = args.contains("--interactive") && payload.hookEventName == "PermissionRequest"
let env = HookEnvelope(
    payload: payload, pid: getppid(),
    termProgram: ProcessInfo.processInfo.environment["TERM_PROGRAM"],
    expectsReply: interactive)

guard let reply = NotchClient.send(env, replyTimeoutSec: 590) else { exit(0) }

// Translate the notch's answer into Claude Code's PermissionRequest decision schema.
switch reply.decision {
case .ask: exit(0)  // no output => Claude Code shows its normal prompt
case .allow, .deny:
    var decision: [String: Any] = ["behavior": reply.decision.rawValue]
    if reply.decision == .deny { decision["message"] = reply.reason ?? "Denied from Notchbot" }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    if let d = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(d) }
    exit(0)
}
