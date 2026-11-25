import Foundation

public enum InstallerError: LocalizedError, Equatable {
    case notAJSONObject
    case unexpectedShape(String)
    case changedWhileWriting

    public var errorDescription: String? {
        switch self {
        case .notAJSONObject: "settings.json is not a JSON object; left it untouched."
        case .unexpectedShape(let key): "settings.json has an unexpected shape at “\(key)”; left it untouched."
        case .changedWhileWriting:
            "settings.json changed while it was being updated (another tool wrote to it). Nothing was changed; try again."
        }
    }
}

/// A settings.json opened for a read-modify-write. Guards the user's config:
/// follows symlinks (dotfile managers), preserves permissions, skips no-op writes, and refuses to write if
/// something else modified the file in the meantime.
struct SettingsFile {
    let url: URL  // symlink-resolved
    var root: [String: Any]
    private let existed: Bool
    private let mtime: Date?
    private let permissions: NSNumber?

    init(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        self.url = resolved
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        existed = attrs != nil
        mtime = attrs?[.modificationDate] as? Date
        permissions = attrs?[.posixPermissions] as? NSNumber
        guard existed else { root = [:]; return }
        let d = try Data(contentsOf: resolved)
        if d.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { root = [:]; return }
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw InstallerError.notAJSONObject }
        root = o
    }

    /// Writes `newRoot` unless it equals what is on disk. Returns the pristine-backup URL if one was created.
    @discardableResult
    func save(_ newRoot: [String: Any]) throws -> (wrote: Bool, backup: URL?) {
        if existed, NSDictionary(dictionary: root).isEqual(to: newRoot) { return (false, nil) }
        // Optimistic concurrency: bail out if the file changed since we read it.
        let now = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if now != mtime { throw InstallerError.changedWhileWriting }

        var backup: URL?
        let b = url.appendingPathExtension("claude-notch.bak")
        if existed, !FileManager.default.fileExists(atPath: b.path) {
            try FileManager.default.copyItem(at: url, to: b)
            backup = b
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONSerialization.data(withJSONObject: newRoot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: url, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return (true, backup)
    }
}

/// Adds / removes Claude Notch hooks in `~/.claude/settings.json` without disturbing anything else
/// (other tools such as terminal integrations register hooks on the same events).
///
/// Notes: the file is re-serialized with sorted keys, so a hand-edited file may be reordered/reindented on the
/// first change. The original is kept once as `settings.json.claude-notch.bak`.
public enum HookInstaller {
    public static let marker = "claude-notch-hook"
    public static let observedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "SessionEnd",
    ]
    public static let permissionEvent = "PermissionRequest"

    public struct Result: Equatable {
        public var added: [String]
        public var removed: [String]
        public var backup: URL?
    }

    // MARK: command strings

    /// `"/path with spaces/claude-notch-hook"`, with the characters the shell treats specially inside
    /// double quotes escaped.
    static func shellQuoted(_ path: String) -> String {
        var out = "\""
        for ch in path {
            if "\\\"$`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out + "\""
    }

    /// The executable a hook command starts with (understands the quoting `shellQuoted` produces).
    static func executable(of command: String) -> String {
        let c = Substring(command.trimmingCharacters(in: .whitespaces))
        guard c.first == "\"" else { return String(c.prefix { !$0.isWhitespace }) }
        var out = ""
        var escaped = false
        for ch in c.dropFirst() {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out
    }

    /// True only for a hook whose executable is named exactly `claude-notch-hook`; a foreign command that
    /// merely mentions the name (a wrapper script, an argument) is not ours.
    static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return (executable(of: command) as NSString).lastPathComponent == marker
    }

    // MARK: shape checks (throw instead of silently overwriting something unexpected)

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let v = root["hooks"] else { return [:] }
        guard let o = v as? [String: Any] else { throw InstallerError.unexpectedShape("hooks") }
        return o
    }

    private static func groups(_ hooks: [String: Any], _ event: String) throws -> [[String: Any]] {
        guard let v = hooks[event] else { return [] }
        guard let a = v as? [[String: Any]] else { throw InstallerError.unexpectedShape("hooks.\(event)") }
        for g in a { if let h = g["hooks"], !(h is [[String: Any]]) { throw InstallerError.unexpectedShape("hooks.\(event)[].hooks") } }
        return a
    }

    /// Removes our entries from a matcher group; returns nil if the group becomes empty.
    private static func stripOurs(_ group: [String: Any]) -> [String: Any]? {
        guard var hs = group["hooks"] as? [[String: Any]] else { return group }
        hs.removeAll { isOurs($0["command"] as? String) }
        if hs.isEmpty { return nil }
        var g = group
        g["hooks"] = hs
        return g
    }

    // MARK: install / uninstall

    public static func install(hookPath: String, interactivePermissions: Bool, settings: URL = Paths.claudeSettings) throws -> Result {
        let file = try SettingsFile(settings)
        var root = file.root
        var hooks = try hooksObject(root)
        var added: [String] = []
        for event in observedEvents + [permissionEvent] {
            var gs = try groups(hooks, event).compactMap { stripOurs($0) }
            if event == permissionEvent && !interactivePermissions {
                hooks[event] = gs.isEmpty ? nil : gs  // observe-only: no hook on the prompt itself
                continue
            }
            let quoted = shellQuoted(hookPath)
            var entry: [String: Any] = ["type": "command", "command": event == permissionEvent ? quoted + " --interactive" : quoted]
            if event == permissionEvent { entry["timeout"] = 600 }
            gs.append(["hooks": [entry]])
            hooks[event] = gs
            added.append(event)
        }
        root["hooks"] = hooks
        let r = try file.save(root)
        return Result(added: added, removed: [], backup: r.backup)
    }

    public static func uninstall(settings: URL = Paths.claudeSettings) throws -> Result {
        let file = try SettingsFile(settings)
        var root = file.root
        guard root["hooks"] != nil else { return Result(added: [], removed: [], backup: nil) }
        var hooks = try hooksObject(root)
        var removed: [String] = []
        for event in hooks.keys {
            let gs = try groups(hooks, event)
            let kept = gs.compactMap { stripOurs($0) }
            let changed = kept.count != gs.count || zip(kept, gs).contains { !NSDictionary(dictionary: $0).isEqual(to: $1) }
            if changed { removed.append(event) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        guard !removed.isEmpty else { return Result(added: [], removed: [], backup: nil) }  // nothing of ours: don't touch the file
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let r = try file.save(root)
        return Result(added: [], removed: removed.sorted(), backup: r.backup)
    }

    public static func isInstalled(settings: URL = Paths.claudeSettings) -> Bool {
        guard let file = try? SettingsFile(settings), let hooks = file.root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { v in
            (v as? [[String: Any]])?.contains { g in
                (g["hooks"] as? [[String: Any]])?.contains { isOurs($0["command"] as? String) } == true
            } == true
        }
    }

    // MARK: status line (quota gauges). Single-slot setting, so we only claim it when it is free.

    public enum StatusLineResult: Equatable { case installed, alreadyInstalled, skippedExisting(command: String) }

    public static func installStatusLine(hookPath: String, settings: URL = Paths.claudeSettings) throws -> StatusLineResult {
        let file = try SettingsFile(settings)
        var root = file.root
        if let v = root["statusLine"] {
            guard let sl = v as? [String: Any] else { return .skippedExisting(command: "(custom status line)") }
            let cmd = sl["command"] as? String ?? ""
            return isOurs(cmd) ? .alreadyInstalled : .skippedExisting(command: cmd)
        }
        root["statusLine"] = ["type": "command", "command": shellQuoted(hookPath) + " --statusline"]
        try file.save(root)
        return .installed
    }

    public static func uninstallStatusLine(settings: URL = Paths.claudeSettings) throws {
        let file = try SettingsFile(settings)
        var root = file.root
        guard let sl = root["statusLine"] as? [String: Any], isOurs(sl["command"] as? String) else { return }
        root["statusLine"] = nil
        try file.save(root)
    }

    public static func isStatusLineInstalled(settings: URL = Paths.claudeSettings) -> Bool {
        guard let file = try? SettingsFile(settings), let sl = file.root["statusLine"] as? [String: Any] else { return false }
        return isOurs(sl["command"] as? String)
    }
}
