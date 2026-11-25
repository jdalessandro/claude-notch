import Foundation

/// How the user pays for Claude. Decides whether dollar figures are meaningful.
public enum BillingMode: Sendable, Equatable {
    /// Claude.ai subscription (Pro/Max/...). `$` from Claude Code is only a list-price estimate here;
    /// the real constraint is the quota windows.
    case subscription(plan: String?)
    /// Pay-as-you-go API key / gateway / cloud provider: dollars are real money.
    case api
}

public enum PlanDetector {
    /// Environment flags that route Claude Code through a cloud provider (always pay-as-you-go).
    static let providerFlags = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]

    /// Detects the billing mode for the current user: process environment, the `env` block and `apiKeyHelper`
    /// of settings.json (a GUI app launched from the Dock does not inherit shell exports), and the login
    /// recorded in `.claude.json` (honoring `CLAUDE_CONFIG_DIR`).
    public static func detectForCurrentUser() -> BillingMode {
        let env = ProcessInfo.processInfo.environment
        let claudeJSON: URL
        if let d = env["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            claudeJSON = URL(fileURLWithPath: d).appendingPathComponent(".claude.json")
        } else {
            claudeJSON = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        }
        return detect(env: env, claudeJSON: claudeJSON, settings: Paths.claudeSettings)
    }

    /// Pure and explicit about every input so tests never touch the real config.
    public static func detect(env processEnv: [String: String], claudeJSON: URL, settings: URL? = nil) -> BillingMode {
        var env = processEnv
        if let settings, let d = try? Data(contentsOf: settings),
            let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        {
            if let helper = root["apiKeyHelper"] as? String, !helper.isEmpty { return .api }
            if let block = root["env"] as? [String: Any] {
                for (k, v) in block where env[k] == nil { env[k] = (v as? String) ?? "\(v)" }
            }
        }
        func truthy(_ k: String) -> Bool {
            guard let v = env[k]?.lowercased(), !v.isEmpty else { return false }
            return !["0", "false", "no", "off"].contains(v)
        }
        if providerFlags.contains(where: truthy) { return .api }
        if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { return .api }
        if let t = env["ANTHROPIC_AUTH_TOKEN"], !t.isEmpty { return .api }
        if let base = env["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespaces), !base.isEmpty {
            // Tolerate scheme-less values like "gateway.corp:8080" and any hostname casing.
            let withScheme = base.contains("://") ? base : "https://" + base
            if (URL(string: withScheme)?.host?.lowercased() ?? base.lowercased()) != "api.anthropic.com" { return .api }
        }
        guard let d = try? Data(contentsOf: claudeJSON),
            let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
            let acct = root["oauthAccount"] as? [String: Any]
        else { return .api }
        let billing = (acct["billingType"] as? String ?? "").lowercased()
        let org = (acct["organizationType"] as? String ?? "").lowercased()
        let tier = (acct["organizationRateLimitTier"] as? String ?? "").lowercased()
        guard billing.contains("subscription") || org.hasPrefix("claude_") else { return .api }
        var plan: String? = org.hasPrefix("claude_") ? String(org.dropFirst(7)).capitalized : nil
        if let r = tier.range(of: #"\d+x$"#, options: .regularExpression), plan != nil { plan! += " " + tier[r] }
        return .subscription(plan: plan)
    }
}

public struct QuotaWindow: Sendable, Equatable, Identifiable {
    /// Key in the status line's `rate_limits` object, e.g. `five_hour`, `seven_day`, `seven_day_opus`.
    public var id: String
    public var title: String
    /// Always within 0...100.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var fraction: Double { min(1, max(0, usedPercent / 100)) }

    public init(id: String = "", title: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.id = id
        self.title = title ?? QuotaState.title(for: id)
        self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
        self.resetsAt = resetsAt
    }
}

/// Rate-limit windows as reported by Claude Code's status line (`rate_limits`), subscribers only.
/// Windows are discovered by key, so per-model weekly limits appear without code changes.
public struct QuotaState: Sendable, Equatable {
    public var windows: [QuotaWindow]
    public var updatedAt: Date

    public var fiveHour: QuotaWindow? { windows.first { $0.id == "five_hour" } }
    public var sevenDay: QuotaWindow? { windows.first { $0.id == "seven_day" } }

    public init(windows: [QuotaWindow], updatedAt: Date = Date()) {
        self.windows = windows
        self.updatedAt = updatedAt
    }
    public init(fiveHour: QuotaWindow? = nil, sevenDay: QuotaWindow? = nil, updatedAt: Date = Date()) {
        var w: [QuotaWindow] = []
        if var f = fiveHour { f.id = "five_hour"; f.title = Self.title(for: "five_hour"); w.append(f) }
        if var d = sevenDay { d.id = "seven_day"; d.title = Self.title(for: "seven_day"); w.append(d) }
        self.init(windows: w, updatedAt: updatedAt)
    }

    /// The status line only reports on activity, so a window whose reset time has passed is stale: show it as
    /// freshly reset (0%, no countdown) instead of a frozen, possibly red, percentage.
    public func refreshed(now: Date = Date()) -> QuotaState {
        var s = self
        s.windows = windows.map { w in
            guard let r = w.resetsAt, r <= now else { return w }
            return QuotaWindow(id: w.id, title: w.title, usedPercent: 0, resetsAt: nil)
        }
        return s
    }

    /// "five_hour" -> "5-hour limit", "seven_day" -> "Weekly · all models", "seven_day_opus" -> "Weekly · Opus".
    public static func title(for key: String) -> String {
        if key == "five_hour" { return "5-hour limit" }
        if key == "seven_day" { return "Weekly · all models" }
        if key.hasPrefix("seven_day_") {
            let model = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
            return "Weekly · " + model.prefix(1).uppercased() + model.dropFirst()
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func order(_ key: String) -> Int { key == "five_hour" ? 0 : key == "seven_day" ? 1 : 2 }

    /// `resets_at` is epoch seconds, but tolerate milliseconds (a value that large would otherwise be the year 58000).
    static func date(fromEpoch t: Double) -> Date? {
        guard t.isFinite, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
    }

    public static func parse(_ v: JSONValue?, now: Date = Date()) -> QuotaState? {
        guard case .object(let o)? = v else { return nil }
        var ws: [QuotaWindow] = []
        for (key, val) in o where key.hasPrefix("five_hour") || key.hasPrefix("seven_day") {
            guard case .number(let pct)? = val["used_percentage"], pct.isFinite else { continue }
            var reset: Date?
            if case .number(let t)? = val["resets_at"] { reset = date(fromEpoch: t) }
            ws.append(QuotaWindow(id: key, usedPercent: pct, resetsAt: reset))
        }
        guard !ws.isEmpty else { return nil }
        ws.sort { (order($0.id), $0.id) < (order($1.id), $1.id) }
        return QuotaState(windows: ws, updatedAt: now)
    }
}

public struct UsageWindows: Sendable, Equatable {
    public var fiveHour = TokenUsage()
    public var today = TokenUsage()
    public var week = TokenUsage()
    public var updatedAt: Date?
    public init() {}
}

/// Sums token usage across every local Claude Code transcript (CLI + desktop, main + subagents) into
/// rolling windows. Incremental: each file is read once, then only appended bytes.
///
/// Requests are de-duplicated by `requestId` **globally**, so a resumed or forked session that copies earlier
/// history into a new transcript does not double-count. Note the 5-hour figure is a rolling window of local
/// activity; the status-line quota (Anthropic's own anchored window) is authoritative when available.
public final class UsageAggregator {
    private struct FileState {
        var offset: UInt64 = 0
        var carry = Data()
        var inode: UInt64 = 0
    }
    private var files: [URL: FileState] = [:]
    private var requests: [String: (at: Date, usage: TokenUsage)] = [:]
    private let root: URL
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    // Whitespace-tolerant prefilter: cheap byte searches before paying for JSON parsing.
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let chunkBytes = 4 * 1024 * 1024
    static let horizon: TimeInterval = 8 * 86_400

    public init(root: URL = Paths.claudeDir.appendingPathComponent("projects")) { self.root = root }

    public func refresh(now: Date = Date(), calendar: Calendar = .current) -> UsageWindows {
        let cutoff = now.addingTimeInterval(-Self.horizon)
        var live = Set<URL>()
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let m = rv?.contentModificationDate, m >= cutoff else { continue }
                live.insert(url)
                ingest(url)
            }
        }
        for k in files.keys where !live.contains(k) { files[k] = nil }
        requests = requests.filter { $0.value.at >= cutoff }  // entries older than the horizon can never matter again

        let t5 = now.addingTimeInterval(-5 * 3600)
        let t7 = now.addingTimeInterval(-7 * 86_400)
        let t0 = calendar.startOfDay(for: now)
        var w = UsageWindows()
        w.updatedAt = now
        for (at, u) in requests.values {
            if at >= t7 { w.week += u }
            if at >= t0 { w.today += u }
            if at >= t5 { w.fiveHour += u }
        }
        return w
    }

    private func ingest(_ url: URL) {
        var st = files[url] ?? FileState()
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (try? h.seekToEnd()) ?? 0
        // Truncated, or replaced by a different file (even a larger one): start over. Re-reading is safe
        // because requests are keyed globally.
        if size < st.offset || (st.inode != 0 && inode != 0 && inode != st.inode) { st = FileState() }
        st.inode = inode
        while size > st.offset {
            try? h.seek(toOffset: st.offset)
            guard let chunk = try? h.read(upToCount: Self.chunkBytes), !chunk.isEmpty else { break }
            st.offset += UInt64(chunk.count)
            var buf = st.carry
            buf.append(chunk)
            guard let nl = buf.lastIndex(of: 0x0A) else { st.carry = buf; continue }
            st.carry = Data(buf[buf.index(after: nl)...])
            for line in buf[...nl].split(separator: 0x0A, omittingEmptySubsequences: true) { record(line) }
        }
        files[url] = st
    }

    private func record(_ line: Data.SubSequence) {
        guard line.range(of: Self.assistantMarker) != nil, line.range(of: Self.usageMarker) != nil,
            let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            (o["type"] as? String) == "assistant",
            let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
            let ts = o["timestamp"] as? String, let at = iso.date(from: ts) ?? isoPlain.date(from: ts)
        else { return }
        let usage = TokenUsage(
            input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
        let key = (o["requestId"] as? String) ?? (msg["id"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
        if let old = requests[key] {  // streamed as several lines, or copied into another transcript: count once
            requests[key] = (
                old.at,
                TokenUsage(
                    input: max(old.usage.input, usage.input), output: max(old.usage.output, usage.output),
                    cacheRead: max(old.usage.cacheRead, usage.cacheRead), cacheWrite: max(old.usage.cacheWrite, usage.cacheWrite))
            )
        } else {
            requests[key] = (at, usage)
        }
    }
}

extension TokenUsage {
    /// Tokens that meaningfully consume quota: fresh input, output, and cache writes. Cache reads are
    /// excluded; they dominate raw totals (tens of millions) while costing almost nothing.
    public var work: Int { input + output + cacheWrite }
}
