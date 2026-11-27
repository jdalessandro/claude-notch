import Foundation
import Testing

@testable import NotchbotCore

@Suite struct InstallerSafety {
    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("is-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func bytes(_ u: URL) throws -> Data { try Data(contentsOf: u) }

    @Test func symlinkedSettingsStaysASymlinkAndTargetIsUpdated() throws {
        let d = try dir()
        let real = d.appendingPathComponent("dotfiles-settings.json"), link = d.appendingPathComponent("settings.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: false, settings: link)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)  // link not replaced by a file
        #expect(HookInstaller.isInstalled(settings: real))
    }

    @Test func filePermissionsArePreserved() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        try "{}".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        let perm = (try FileManager.default.attributesOfItem(atPath: f.path))[.posixPermissions] as? NSNumber
        #expect(perm?.intValue == 0o600)
    }

    @Test func unexpectedShapesThrowAndLeaveTheFileByteIdentical() throws {
        let d = try dir()
        let bad = [#"{"hooks":[1,2,3]}"#, #"{"hooks":{"Stop":"weird"}}"#, #"{"hooks":{"Stop":[{"hooks":"nope"}]}}"#, "[1,2]"]
        for (i, json) in bad.enumerated() {
            let f = d.appendingPathComponent("s\(i).json")
            try json.write(to: f, atomically: true, encoding: .utf8)
            let before = try bytes(f)
            #expect(throws: InstallerError.self) {
                try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
            }
            #expect(try bytes(f) == before, "\(json)")
        }
    }

    @Test func uninstallWithNothingToRemoveDoesNotRewriteTheFile() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        // Deliberately unsorted, odd spacing, a float that would not survive a round trip unchanged.
        try #"{ "zeta": 0.1,   "alpha": 1,  "hooks": {"Stop": [{"hooks": [{"type":"command","command":"/usr/bin/other"}]}]} }"#
            .write(to: f, atomically: true, encoding: .utf8)
        let before = try bytes(f)
        let r = try HookInstaller.uninstall(settings: f)
        #expect(r.removed.isEmpty && r.backup == nil)
        #expect(try bytes(f) == before)
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathExtension("notchbot.bak").path))
    }

    @Test func foreignHooksMentioningOurNameSurvive() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        let foreign = ["/opt/x/my-notchbot-hook-wrapper", "/usr/bin/other --note notchbot-hook", "/bin/echo notchbot-hook"]
        let entries = foreign.map { #"{"type":"command","command":""# + $0 + #""}"# }.joined(separator: ",")
        try (#"{"hooks":{"Stop":[{"hooks":["# + entries + "]}]}}").write(to: f, atomically: true, encoding: .utf8)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: false, settings: f)
        _ = try HookInstaller.uninstall(settings: f)
        let text = String(decoding: try bytes(f), as: UTF8.self)
        for c in foreign { #expect(text.contains(c), "\(c)") }
        #expect(!HookInstaller.isInstalled(settings: f))
    }

    @Test func hookPathsWithSpacesQuotesAndDollarsRoundTrip() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        let path = #"/Users/me/My Apps/we"ird $HOME `x`/notchbot-hook"#
        _ = try HookInstaller.install(hookPath: path, interactivePermissions: true, settings: f)
        let obj = try JSONSerialization.jsonObject(with: bytes(f)) as! [String: Any]
        let stop = ((obj["hooks"] as! [String: Any])["Stop"] as! [[String: Any]])[0]
        let cmd = ((stop["hooks"] as! [[String: Any]])[0])["command"] as! String
        #expect(HookInstaller.executable(of: cmd) == path)  // the shell would see exactly the original path
        #expect(cmd.contains(#"\$HOME"#) && cmd.contains(#"\""#) && cmd.contains(#"\`x\`"#))
        #expect(HookInstaller.isInstalled(settings: f))
        _ = try HookInstaller.uninstall(settings: f)
        #expect(!HookInstaller.isInstalled(settings: f))
    }

    @Test func detectsAConcurrentWriterInsteadOfClobberingIt() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        try "{}".write(to: f, atomically: true, encoding: .utf8)
        let file = try SettingsFile(f)
        // Another tool writes between our read and our write.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.path)
        #expect(throws: InstallerError.changedWhileWriting) { try file.save(["hooks": [String: Any]()]) }
    }

    @Test func installTwiceIsIdempotentAndSecondRunWritesNothing() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        let once = try bytes(f)
        let second = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        #expect(try bytes(f) == once && second.backup == nil)
    }

    @Test func observeOnlyInstallThenUninstallLeavesNoResidue() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        try #"{"model":"opus"}"#.write(to: f, atomically: true, encoding: .utf8)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: false, settings: f)
        _ = try HookInstaller.uninstall(settings: f)
        let obj = try JSONSerialization.jsonObject(with: bytes(f)) as! [String: Any]
        #expect(obj["hooks"] == nil && obj["model"] as? String == "opus")
    }

    @Test func unicodeAndLargeNumbersSurviveAnInstall() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        try #"{"note":"héllo ✓ 日本語","big":9007199254740993,"nested":{"a":[1,2,{"b":null}]}}"#.write(
            to: f, atomically: true, encoding: .utf8)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: false, settings: f)
        let obj = try JSONSerialization.jsonObject(with: bytes(f)) as! [String: Any]
        #expect(obj["note"] as? String == "héllo ✓ 日本語" && (obj["nested"] as? [String: Any])?["a"] != nil)
    }

    @Test func statusLineInstallHandlesMalformedExistingValue() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        try #"{"statusLine":"just a string"}"#.write(to: f, atomically: true, encoding: .utf8)
        let before = try bytes(f)
        #expect(
            try HookInstaller.installStatusLine(hookPath: "/x/notchbot-hook", settings: f)
                == .skippedExisting(command: "(custom status line)"))
        #expect(try bytes(f) == before)
    }

    @Test func detectsAnInstallThatPredatesNewerEvents() throws {
        let d = try dir(); let f = d.appendingPathComponent("settings.json")
        #expect(HookInstaller.missingEvents(interactivePermissions: true, settings: f).isEmpty)  // nothing installed: nothing to update
        // An older install: ours on only a few events (no SubagentStart), alongside someone else's hook.
        let ours = #"{"type":"command","command":"\"/x/notchbot-hook\""}"#
        try
            (#"{"hooks":{"Stop":[{"hooks":["# + ours + #"]}],"SubagentStop":[{"hooks":["# + ours
            + #"]}],"SubagentStart":[{"hooks":[{"type":"command","command":"/usr/bin/other"}]}]}}"#)
            .write(to: f, atomically: true, encoding: .utf8)
        let missing = HookInstaller.missingEvents(interactivePermissions: false, settings: f)
        // someone else's hook doesn't count as ours
        #expect(missing.contains("SubagentStart") && missing.contains("PreToolUse") && !missing.contains("Stop"))
        #expect(!missing.contains("PermissionRequest"))  // observe-only: not expected
        #expect(HookInstaller.missingEvents(interactivePermissions: true, settings: f).contains("PermissionRequest"))
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        #expect(HookInstaller.missingEvents(interactivePermissions: true, settings: f).isEmpty)  // a fresh install is complete
    }
}
