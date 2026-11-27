import Foundation
import Testing

@testable import NotchbotCore

@Suite struct Installer {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("i-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    @Test func mergePreservesForeignHooksAndUninstallsCleanly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inst-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("settings.json")
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/other"}]}]}}"#
        try original.write(to: f, atomically: true, encoding: .utf8)

        let r = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        #expect(r.added.contains("PermissionRequest") && r.backup != nil)
        #expect(HookInstaller.isInstalled(settings: f))
        // Idempotent: installing twice must not duplicate.
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: true, settings: f)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        let stop = (obj["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        #expect(stop.count == 2)
        #expect(obj["model"] as? String == "opus")

        _ = try HookInstaller.uninstall(settings: f)
        #expect(!HookInstaller.isInstalled(settings: f))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        #expect(((after["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count == 1)
        #expect((after["hooks"] as! [String: Any])["PermissionRequest"] == nil)
    }

    @Test func installReplacesHooksWrittenUnderTheOldName() throws {
        let d = try tmp(); let f = d.appendingPathComponent("settings.json")
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/claude-notch-hook"}]}]}}"#.write(
            to: f, atomically: true, encoding: .utf8)
        _ = try HookInstaller.install(hookPath: "/x/notchbot-hook", interactivePermissions: false, settings: f)
        let text = try String(contentsOf: f, encoding: .utf8)
        #expect(!text.contains("claude-notch-hook") && text.contains("notchbot-hook"))
    }

    @Test func statusLineInstallRespectsExistingAndRemovesOnlyOurs() throws {
        let d = try tmp(); let f = d.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"/usr/local/bin/mine"}}"#.write(to: f, atomically: true, encoding: .utf8)
        #expect(
            try HookInstaller.installStatusLine(hookPath: "/x/notchbot-hook", settings: f)
                == .skippedExisting(command: "/usr/local/bin/mine"))
        try HookInstaller.uninstallStatusLine(settings: f)  // not ours: untouched
        #expect(String(decoding: try Data(contentsOf: f), as: UTF8.self).contains("/usr/local/bin/mine"))
        let g = d.appendingPathComponent("empty.json"); try "{}".write(to: g, atomically: true, encoding: .utf8)
        #expect(try HookInstaller.installStatusLine(hookPath: "/x/notchbot-hook", settings: g) == .installed)
        #expect(try HookInstaller.installStatusLine(hookPath: "/x/notchbot-hook", settings: g) == .alreadyInstalled)
        #expect(HookInstaller.isStatusLineInstalled(settings: g))
        try HookInstaller.uninstallStatusLine(settings: g)
        #expect(!HookInstaller.isStatusLineInstalled(settings: g))
    }
}
