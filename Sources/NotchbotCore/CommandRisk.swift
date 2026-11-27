import Foundation

/// Flags requests an engineer should read in full before approving. Heuristic and deliberately conservative: a
/// false positive only costs one extra look at the full card, a false negative is the thing to avoid.
public enum CommandRisk {
    /// Commands longer than this don't fit the one-line inline row, so they get the full card first.
    public static let inlineLimit = 48

    private static let patterns: [NSRegularExpression] = [
        #"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR]"#,  // rm -rf, rm -fr, rm -r
        #"\brm\s+.*--recursive"#,
        #"\bgit\s+push\b.*(\s--force\b|\s--force-with-lease\b|\s-[a-zA-Z]*f\b|\s\+\S)"#,
        #"\bgit\s+reset\b.*--hard"#,
        #"\bgit\s+(clean)\b.*-[a-zA-Z]*f"#,
        #"\bgit\s+checkout\s+(--\s+)?\.(\s|$)"#,
        #"(^|[;&|(]\s*|\s)sudo\b"#,
        #"\bdrop\s+(table|database|schema)\b"#,
        #"\btruncate\s+table\b"#,
        #"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#,
        #"\bchmod\s+(-[a-zA-Z]+\s+)*777\b"#,
        #"\bmkfs\b|\bdd\s+if="#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// True when `command` matches a known-dangerous shape (`rm -rf`, force-push, hard reset, sudo, SQL drops,
    /// pipe-to-shell, ...) or redirects output outside `cwd`.
    public static func isDestructive(command: String, cwd: String? = nil) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        if patterns.contains(where: { $0.firstMatch(in: command, range: range) != nil }) { return true }
        return redirectTargets(command).contains { isOutside($0, cwd: cwd) }
    }

    /// True when a file tool (`Write`, `Edit`, ...) targets a path outside the session's working directory.
    public static func isOutsideRepo(path: String, cwd: String?) -> Bool { isOutside(path, cwd: cwd) }

    /// Classifies a pending tool call from its raw input (not the clipped summary).
    public static func isDestructive(tool: String?, input: JSONValue?, cwd: String?) -> Bool {
        switch tool {
        case "Bash": return input?["command"]?.stringValue.map { isDestructive(command: $0, cwd: cwd) } ?? false
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let p = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue else { return false }
            return isOutsideRepo(path: p, cwd: cwd)
        default: return false
        }
    }

    private static func redirectTargets(_ command: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?<![<>&0-9])>>?\s*(["']?)([~/][^\s"';|&]*)"#) else { return [] }
        let ns = command as NSString
        return re.matches(in: command, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 2)) }
    }

    private static func isOutside(_ path: String, cwd: String?) -> Bool {
        if path == "/dev/null" || path.hasPrefix("/dev/std") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
            return false
        }
        guard let cwd, !cwd.isEmpty else { return false }
        let expanded = path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
        guard expanded.hasPrefix("/") else { return false }  // relative paths stay in the repo
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        let std = NSString(string: expanded).standardizingPath
        return !(std + "/").hasPrefix(root)
    }
}

/// Timing rules that keep a tap from landing on something other than what the user aimed at. The island can't
/// report hover, and pages turn by themselves, so what is under the cursor can change between aim and click.
public enum IslandGuard {
    /// An Allow tap for a request that became visible less than this long ago is ignored.
    public static let tapDelay: TimeInterval = 0.8
    /// Pages don't turn this long after the featured prompt changed.
    public static let promptSettle: TimeInterval = 1.5

    /// Whether the island may turn to the next page by itself right now.
    public static func canAutoTurn(state: NotchActivityState, promptChangedAt: Date, now: Date = .now) -> Bool {
        guard state.pages > 1 else { return false }
        if state.rows.contains(where: { $0.kind == .approval && $0.requestId != nil }) { return false }
        return now.timeIntervalSince(promptChangedAt) >= promptSettle
    }

    /// Whether an Allow tap may be honoured, given when its request became visible (nil = unknown, allow).
    public static func allowAccepted(visibleSince: Date?, now: Date = .now) -> Bool {
        guard let visibleSince else { return true }
        return now.timeIntervalSince(visibleSince) >= tapDelay
    }
}
