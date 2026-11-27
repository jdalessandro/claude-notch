import Foundation

/// Context-window sizes learned from Claude Code's status line (`context_window.context_window_size`).
/// Nothing is hardcoded: the status line is the source of truth, and what it reports is remembered on disk
/// so idle sessions and app restarts keep the right number until the next report.
public struct ContextWindowCache: Codable, Sendable, Equatable {
    public var bySession: [String: Int] = [:]

    public init() {}

    public static var storeURL: URL { Paths.supportDir.appendingPathComponent("context-windows.json") }

    public static func load(from url: URL = storeURL) -> ContextWindowCache {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Self.self, from: d) else { return .init() }
        return c
    }

    public func save(to url: URL = storeURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: url, options: .atomic) }
    }

    public mutating func record(size: Int, session: String) {
        guard size > 0 else { return }
        bySession[session] = size
        if bySession.count > 500 { bySession = Dictionary(uniqueKeysWithValues: bySession.suffix(250).map { ($0.key, $0.value) }) }
    }

    public func size(session: String) -> Int? { bySession[session] }
}
