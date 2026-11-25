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
}
