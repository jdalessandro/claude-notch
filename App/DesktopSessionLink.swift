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

    private struct Entry { var file: URL; var mtime: Date; var focused: Date? }
    private static var cache: [String: Entry] = [:]

    /// When the user last focused this session in Claude Desktop (`lastFocusedAt`). The session file is only re-read
    /// when it changes on disk.
    static func lastFocused(forCLISession cliId: String) -> Date? {
        let fm = FileManager.default
        if var e = cache[cliId] {
            guard let m = (try? e.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { cache[cliId] = nil; return nil }
            if m != e.mtime { e.mtime = m; e.focused = read(e.file); cache[cliId] = e }
            return e.focused
        }
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["cliSessionId"] as? String == cliId
            else { continue }
            let m = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let f = focusDate(obj)
            cache[cliId] = Entry(file: file, mtime: m, focused: f)
            return f
        }
        return nil
    }

    private static func read(_ file: URL) -> Date? {
        guard let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return focusDate(obj)
    }

    private static func focusDate(_ obj: [String: Any]) -> Date? {
        (obj["lastFocusedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
