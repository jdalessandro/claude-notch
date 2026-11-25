import Foundation

/// Display formatting shared by the UI and tests.
public enum Fmt {
    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: "\(n)"
        case ..<1_000_000: String(format: n < 10_000 ? "%.1fk" : "%.0fk", Double(n) / 1_000)
        default: String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
    public static func cost(_ c: Double) -> String { c < 0.01 && c > 0 ? "<$0.01" : String(format: "$%.2f", c) }
    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m \(s % 60)s" : "\(s / 3600)h \(s % 3600 / 60)m"
    }
    /// Largest-unit countdown, as Claude Desktop shows it: "6d", "4h", "25m".
    public static func until(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        return s >= 86_400 ? "\(s / 86_400)d" : s >= 3600 ? "\(s / 3600)h" : "\(max(1, s / 60))m"
    }
    /// "just now" / "3m ago" / "2h ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        return s < 20 ? "just now" : s < 3600 ? "\(max(1, s / 60))m ago" : "\(s / 3600)h ago"
    }
    public static func label(_ s: AgentStatus) -> String {
        switch s {
        case .working: "Working"
        case .compacting: "Compacting"
        case .needsPermission: "Needs permission"
        case .needsInput: "Waiting for you"
        case .done: "Done"
        case .failed: "Failed"
        case .ended: "Ended"
        }
    }

    // MARK: text from Claude

    /// Flattens a markdown reply into one line of *inline* markdown (bold, code, links survive for rendering):
    /// fences, heading/quote/list markers and blank lines are dropped, since the island shows a few lines.
    public static func inlineMarkdown(_ s: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }  // code inside a fence is not prose
            line = line.replacingOccurrences(of: #"^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out.joined(separator: " ")
    }

    /// Like `inlineMarkdown` but with the inline marks removed too, for places that can't render them.
    public static func plainText(_ s: String) -> String {
        var t = inlineMarkdown(s)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "~~", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t
    }

    /// Text Claude Code delivers as a "prompt" that the user never typed: subagent hand-backs, task
    /// notifications, system reminders, interrupts. These must not replace the user's real prompt.
    public static func isSyntheticPrompt(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[Request interrupted") || t.hasPrefix("Caveat:") { return true }
        guard t.hasPrefix("<"),
            let r = t.range(of: #"^<([a-z][a-z0-9_-]*)"#, options: .regularExpression)
        else { return false }
        let tag = String(t[r]).dropFirst()
        let known: Set<String> = [
            "agent-message", "task-notification", "system-reminder", "command-name", "command-message", "command-args",
            "local-command-stdout", "local-command-stderr", "ci-monitor-event", "side-sessions-event", "user-prompt-submit-hook",
        ]
        return known.contains(String(tag))
    }
}
