import Foundation

/// Model context windows read from the catalog Claude Code / the Claude app cache in
/// `~/.claude/cache/model-catalog/*.json` (`runtime.max_input_tokens` per model id). Nothing is hardcoded, so new
/// models and changed windows are picked up as soon as Claude refreshes its catalog.
public struct ModelCatalog: Sendable, Equatable {
    public var windows: [String: Int] = [:]
    public init(windows: [String: Int] = [:]) { self.windows = windows }

    public static var directory: URL { Paths.claudeDir.appendingPathComponent("cache/model-catalog") }

    /// Merges every catalog file; the most recently fetched one wins for a model listed in several.
    public static func load(from dir: URL = directory) -> ModelCatalog {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var parsed: [(fetched: Double, windows: [String: Int])] = []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".badges.json") {
            guard let d = try? Data(contentsOf: f), let w = parse(d) else { continue }
            parsed.append(w)
        }
        var out: [String: Int] = [:]
        for p in parsed.sorted(by: { $0.fetched < $1.fetched }) { out.merge(p.windows) { _, new in new } }
        return ModelCatalog(windows: out)
    }

    static func parse(_ data: Data) -> (fetched: Double, windows: [String: Int])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let catalog = root["catalog"] as? [String: Any], let config = catalog["config"] as? [String: Any],
            let models = config["models"] as? [[String: Any]]
        else { return nil }
        var w: [String: Int] = [:]
        for m in models {
            guard let id = m["id"] as? String, let rt = m["runtime"] as? [String: Any],
                let n = (rt["max_input_tokens"] as? NSNumber)?.intValue, n > 0
            else { continue }
            w[id.lowercased()] = n
        }
        return (((root["fetchedAt"] as? NSNumber)?.doubleValue ?? 0), w)
    }

    /// Window for a model id as it appears in transcripts/status lines. Tolerates suffixes such as `[1m]` and
    /// date stamps by falling back to the longest catalog id that prefixes it.
    public func window(for model: String?) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        let m = model.lowercased()
        if let n = windows[m] { return n }
        return windows.keys.filter { m.hasPrefix($0) }.max(by: { $0.count < $1.count }).flatMap { windows[$0] }
    }
}
