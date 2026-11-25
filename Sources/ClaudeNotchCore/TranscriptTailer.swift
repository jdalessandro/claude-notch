import Foundation

/// Incrementally reads a Claude Code transcript (`~/.claude/projects/<cwd>/<session>.jsonl`)
/// and accumulates token usage. Only new bytes are parsed on each `poll()`.
///
/// Streaming writes the same API request as several `assistant` lines (one per content block)
/// that repeat the same `usage`; we key by `requestId` (falling back to `message.id`) and keep
/// the largest value seen so each request is counted once.
public struct TranscriptSnapshot: Sendable, Equatable {
    public var usage = TokenUsage()
    public var model: String?
    /// Prompt size of the most recent main-thread request = what currently fills the context.
    public var contextTokens = 0
    public var peakContextTokens = 0
    public var requestCount = 0
    public var entrypoint: String?
    public var title: String?
    public var gitBranch: String?
    /// Authoritative cost reported by Claude Code itself (`cost-state` record), if present.
    public var reportedCostUSD: Double?
    public var linesAdded = 0
    public var linesRemoved = 0
    public init() {}
}

public final class TranscriptTailer {
    public let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var carry = Data()
    private var perRequest: [String: TokenUsage] = [:]
    public private(set) var snapshot = TranscriptSnapshot()

    public init(url: URL) { self.url = url }

    @discardableResult
    public func poll() -> TranscriptSnapshot {
        guard let h = try? FileHandle(forReadingFrom: url) else { return snapshot }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // Truncated, or replaced by a different file (which may be larger): start over.
        let ino = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if size < offset || (inode != 0 && ino != 0 && ino != inode) { reset() }
        inode = ino
        guard size > offset else { return snapshot }
        try? h.seek(toOffset: offset)
        guard let chunk = try? h.readToEnd(), !chunk.isEmpty else { return snapshot }
        offset += UInt64(chunk.count)
        var buf = carry + chunk
        // Keep a trailing partial line for the next poll.
        if let nl = buf.lastIndex(of: 0x0A) {
            carry = Data(buf[buf.index(after: nl)...]); buf = Data(buf[...nl])
        } else {
            carry = buf; return snapshot
        }
        for line in buf.split(separator: 0x0A, omittingEmptySubsequences: true) { ingest(Data(line)) }
        recompute()
        return snapshot
    }

    private func reset() {
        offset = 0; carry = Data(); perRequest = [:]; snapshot = TranscriptSnapshot()
    }

    private func ingest(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "ai-title" || type == "custom-title",
            let t = (obj["aiTitle"] ?? obj["customTitle"] ?? obj["title"]) as? String, !t.isEmpty
        {
            snapshot.title = t
        }
        if type == "cost-state" {
            if let c = obj["totalCostUSD"] as? Double { snapshot.reportedCostUSD = c }
            snapshot.linesAdded = obj["totalLinesAdded"] as? Int ?? snapshot.linesAdded
            snapshot.linesRemoved = obj["totalLinesRemoved"] as? Int ?? snapshot.linesRemoved
        }
        if let ep = obj["entrypoint"] as? String { snapshot.entrypoint = ep }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { snapshot.gitBranch = b }
        guard type == "assistant", let msg = obj["message"] as? [String: Any],
            let u = msg["usage"] as? [String: Any]
        else { return }
        let usage = TokenUsage(
            input: u["input_tokens"] as? Int ?? 0,
            output: u["output_tokens"] as? Int ?? 0,
            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
        let key = (obj["requestId"] as? String) ?? (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        if let old = perRequest[key] {
            perRequest[key] = TokenUsage(
                input: max(old.input, usage.input), output: max(old.output, usage.output),
                cacheRead: max(old.cacheRead, usage.cacheRead),
                cacheWrite: max(old.cacheWrite, usage.cacheWrite))
        } else {
            perRequest[key] = usage
        }
        if let m = msg["model"] as? String, m != "<synthetic>" { snapshot.model = m }
        if (obj["isSidechain"] as? Bool) != true {  // subagent traffic doesn't fill main context
            snapshot.contextTokens = usage.input + usage.cacheRead + usage.cacheWrite
            snapshot.peakContextTokens = max(snapshot.peakContextTokens, snapshot.contextTokens)
        }
    }

    private func recompute() {
        snapshot.usage = perRequest.values.reduce(TokenUsage(), +)
        snapshot.requestCount = perRequest.count
    }
}
