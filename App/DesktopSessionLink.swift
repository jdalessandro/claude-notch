import Foundation

/// Maps a Claude Code `session_id` (what hooks report) to the Claude Desktop Code-tab session that owns it, so the
/// Open button can deep-link to that conversation. Desktop keeps one JSON file per session with both ids.
enum DesktopSessionLink {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    /// `claude://claude.ai/epitaxy/local_…`, or nil when the session isn't one Claude Desktop knows about (e.g. plain CLI).
    static func url(forCLISession cliId: String) -> URL? {
        guard !cliId.isEmpty,
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["cliSessionId"] as? String == cliId,
                let local = obj["sessionId"] as? String
            else { continue }
            return URL(string: "claude://claude.ai/epitaxy/\(local)")
        }
        return nil
    }
}
