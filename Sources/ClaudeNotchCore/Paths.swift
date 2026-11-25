import Foundation

/// Well-known locations. Overridable via environment for tests and multiple instances.
public enum Paths {
    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeNotch", isDirectory: true)
    }
    /// Overridable for tests / multiple instances.
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SOCKET"]
            ?? supportDir.appendingPathComponent("notch.sock").path
    }
    public static var pricingURL: URL { supportDir.appendingPathComponent("pricing.json") }
    public static var claudeDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    public static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }
}
