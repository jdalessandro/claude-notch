import Foundation

/// Decides when a finished result has been "reviewed" by looking at it in the island.
///
/// Claude Code emits no "the user read this" signal, so the only honest evidence available is the user
/// deliberately looking at the full result here: pointer over the island, detailed view, for a few seconds.
/// The caller passes only the sessions currently being *viewed* in that sense (not merely on screen, such as
/// the island auto-opening on its own), and a session only counts after viewing it **continuously** for `dwell`.
public struct ReviewGate: Sendable, Equatable {
    public var dwell: TimeInterval
    private var since: [String: Date] = [:]

    public init(dwell: TimeInterval = 5) { self.dwell = dwell }

    /// Feed the sessions being viewed right now. Returns the ones viewed long enough (each reported once).
    public mutating func update(viewing: Set<String>, now: Date) -> [String] {
        since = since.filter { viewing.contains($0.key) }  // looked away: that session's dwell starts over
        var reviewed: [String] = []
        for id in viewing {
            let start = since[id] ?? now
            since[id] = start
            if now.timeIntervalSince(start) >= dwell {
                reviewed.append(id)
                since[id] = nil
            }
        }
        return reviewed.sorted()
    }

    public mutating func reset() { since = [:] }
}
