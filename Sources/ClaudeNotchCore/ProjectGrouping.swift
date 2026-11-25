import Foundation

extension AgentSession {
    /// The folder the project lives in: the repository for a Claude worktree (`<repo>/.claude/worktrees/<name>`),
    /// otherwise the session's own folder. Scratch workspaces share one bucket.
    public var projectRoot: String { ProjectGrouping.root(of: cwd) }
}

/// What the Claude desktop app knows about a session that hooks do not say. Read-only and best effort: the file
/// format is the app's own and may change, so every field is optional and a missing or odd file yields nothing.
public struct DesktopSessionInfo: Sendable, Equatable {
    public var title: String?
    public var originCwd: String?
    /// Pull requests attached to the session that are still open.
    public var openPRs = 0
    /// Session id (the Claude Code one, as hooks report it) of the session this one was started from.
    public var parentId: String?
    public init(title: String? = nil, originCwd: String? = nil, openPRs: Int = 0, parentId: String? = nil) {
        self.title = title; self.originCwd = originCwd; self.openPRs = openPRs; self.parentId = parentId
    }
}

public struct DesktopSessionIndex: Sendable, Equatable {
    /// Keyed by Claude Code session id (`cliSessionId`), which is what hook payloads call `session_id`.
    public var sessions: [String: DesktopSessionInfo] = [:]
    public init(sessions: [String: DesktopSessionInfo] = [:]) { self.sessions = sessions }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Reads `<dir>/<account>/<org>/local_*.json`. Only a handful of fields are read, and nothing is written.
    public static func load(from dir: URL = defaultDirectory) -> DesktopSessionIndex {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return .init()
        }
        var raw: [(local: String, cli: String, obj: [String: Any])] = []
        for case let url as URL in walker {
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                walker.level <= 4,
                let data = try? Data(contentsOf: url),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let local = obj["sessionId"] as? String, let cli = obj["cliSessionId"] as? String
            else { continue }
            if obj["isArchived"] as? Bool == true { continue }
            raw.append((local, cli, obj))
        }
        let cliByLocal = Dictionary(raw.map { ($0.local, $0.cli) }, uniquingKeysWith: { a, _ in a })
        var out: [String: DesktopSessionInfo] = [:]
        for r in raw {
            var info = out[r.cli] ?? DesktopSessionInfo()
            info.title = r.obj["title"] as? String
            info.originCwd = r.obj["originCwd"] as? String ?? r.obj["cwd"] as? String
            info.openPRs =
                (r.obj["prs"] as? [[String: Any]] ?? []).filter {
                    !["merged", "closed"].contains(($0["state"] as? String ?? "").lowercased())
                }.count
            out[r.cli] = info
        }
        // A session lists the sessions it started; invert that into a parent link on each child.
        for r in raw {
            let notes = (r.obj["sideSessionNotes"] as? [[String: Any]] ?? []) + (r.obj["queuedSideSessionNotes"] as? [[String: Any]] ?? [])
            for n in notes {
                if let childLocal = n["sessionId"] as? String, let childCli = cliByLocal[childLocal], childCli != r.cli {
                    out[childCli]?.parentId = r.cli
                }
            }
        }
        return .init(sessions: out)
    }
}

/// One project's sessions, as shown under a header.
public struct ProjectGroup: Identifiable, Sendable, Equatable {
    public var id: String  // the project root
    public var name: String
    /// Sessions in display order. A session started from another one in the same group follows its parent.
    public var rows: [Row]
    public var openPRs: Int
    public var sessionCount: Int { rows.count }
    /// The most urgent state in the group, which colours its dot.
    public var lead: AgentStatus
    public var needsAttention: Int
    public var running: Int

    public struct Row: Identifiable, Sendable, Equatable {
        public var session: AgentSession
        public var isChild: Bool
        public var id: String { session.id }
    }
}

public enum ProjectGrouping {
    public static func root(of cwd: String) -> String {
        let parts = (cwd as NSString).pathComponents
        if let i = parts.firstIndex(of: ".claude"), i > 0, i + 1 < parts.count, parts[i + 1] == "worktrees" {
            return NSString.path(withComponents: Array(parts[..<i]))
        }
        if parts.contains("scratch-workspaces") { return "scratch-workspaces" }
        return cwd
    }

    /// Groups `sessions` (already in display order) by project. Groups are ordered by their most urgent session, then
    /// by recency, so the project that needs you is on top.
    public static func group(_ sessions: [AgentSession], desktop: DesktopSessionIndex = .init()) -> [ProjectGroup] {
        var order: [String] = []
        var buckets: [String: [AgentSession]] = [:]
        for s in sessions {
            let root = ProjectGrouping.root(of: desktop.sessions[s.id]?.originCwd ?? s.cwd)
            if buckets[root] == nil { order.append(root) }
            buckets[root, default: []].append(s)
        }
        return order.map { root in
            let members = buckets[root] ?? []
            let name = members.first.map { projectLabel($0, root: root) } ?? root
            let ids = Set(members.map(\.id))
            // Children directly after their parent; everything else keeps its order.
            let children = Dictionary(
                grouping: members.filter { m in
                    if let p = desktop.sessions[m.id]?.parentId { return ids.contains(p) }
                    return false
                }, by: { desktop.sessions[$0.id]?.parentId ?? "" })
            var rows: [ProjectGroup.Row] = []
            for m in members where !(children.values.joined().contains { $0.id == m.id }) {
                rows.append(.init(session: m, isChild: false))
                for c in children[m.id] ?? [] { rows.append(.init(session: c, isChild: true)) }
            }
            return ProjectGroup(
                id: root, name: name, rows: rows,
                openPRs: members.reduce(0) { $0 + (desktop.sessions[$1.id]?.openPRs ?? 0) },
                lead: members.map(\.status).max { $0.urgency < $1.urgency } ?? .ended,
                needsAttention: members.filter { $0.status.needsAttention || $0.unseen }.count,
                running: members.filter { $0.status == .working || $0.status == .compacting }.count)
        }
    }

    private static func projectLabel(_ s: AgentSession, root: String) -> String {
        root == "scratch-workspaces" ? "Scratch workspace" : (root as NSString).lastPathComponent
    }
}
