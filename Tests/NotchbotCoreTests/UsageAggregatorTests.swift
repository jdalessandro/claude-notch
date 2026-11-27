import Foundation
import Testing

@testable import NotchbotCore

@Suite struct UsageAggregatorTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func root() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("ua-\(UUID())")
        try FileManager.default.createDirectory(at: r.appendingPathComponent("p"), withIntermediateDirectories: true)
        return r
    }
    func line(_ rid: String, ago: TimeInterval, out: Int, spaced: Bool = false, tsFormat: String? = nil) -> String {
        let ts = tsFormat ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago))
        let sep = spaced ? ": " : ":"
        return
            "{\"type\"\(sep)\"assistant\",\"requestId\":\"\(rid)\",\"timestamp\":\"\(ts)\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":\(out),\"cache_read_input_tokens\":1000,\"cache_creation_input_tokens\":5}}}"
    }
    func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func sameRequestInTwoTranscriptsIsCountedOnce() throws {
        let r = try root()
        try write([line("a", ago: 60, out: 100)], to: r.appendingPathComponent("p/original.jsonl"))
        // history copied
        try write([line("a", ago: 60, out: 100), line("b", ago: 30, out: 50)], to: r.appendingPathComponent("p/resumed-copy.jsonl"))
        #expect(UsageAggregator(root: r).refresh(now: now, calendar: utc).fiveHour.output == 150)
    }

    @Test func oldEntriesInARecentlyTouchedFileAreExcluded() throws {
        let r = try root()
        try write([line("old", ago: 9 * 86_400, out: 999), line("new", ago: 60, out: 1)], to: r.appendingPathComponent("p/s.jsonl"))
        let w = UsageAggregator(root: r).refresh(now: now, calendar: utc)
        #expect(w.week.output == 1 && w.fiveHour.output == 1)
    }

    @Test func spacedJSONAndOffsetTimestampsStillCount() throws {
        let r = try root()
        try write(
            [
                line("a", ago: 60, out: 7, spaced: true), line("b", ago: 0, out: 3, tsFormat: "2026-11-25T17:59:00+00:00"),
                line("c", ago: 0, out: 1, tsFormat: "2026-11-25T17:58:00.123Z"),
            ],
            to: r.appendingPathComponent("p/s.jsonl"))
        #expect(UsageAggregator(root: r).refresh(now: now, calendar: utc).fiveHour.output == 11)
    }

    @Test func todayFollowsTheCallersTimezoneAcrossDSTChanges() throws {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        let r = try root()
        // 2026-11-01 is a 25-hour day in New York. Local midnight is 04:00Z; "now" is 22:00Z.
        let cutoverNow = ISO8601DateFormatter().date(from: "2026-11-01T22:00:00Z")!
        func entry(_ id: String, _ iso: String, _ out: Int) -> String { line(id, ago: 0, out: out, tsFormat: iso) }
        try write(
            [entry("before", "2026-11-01T03:59:00Z", 100), entry("after", "2026-11-01T04:01:00Z", 5)],
            to: r.appendingPathComponent("p/s.jsonl"))
        let w = UsageAggregator(root: r).refresh(now: cutoverNow, calendar: ny)
        #expect(w.today.output == 5)
    }

    @Test func replacedLargerFileIsReReadFromTheStart() throws {
        let r = try root(); let f = r.appendingPathComponent("p/s.jsonl")
        try write([line("a", ago: 60, out: 1)], to: f)
        let agg = UsageAggregator(root: r)
        #expect(agg.refresh(now: now, calendar: utc).fiveHour.output == 1)
        // A different, larger file takes its place (new inode) holding different requests.
        try FileManager.default.removeItem(at: f)
        try write([line("x", ago: 50, out: 20), line("y", ago: 40, out: 30), line("z", ago: 30, out: 40)], to: f)
        // the replaced file's earlier request really happened, so it stays counted
        #expect(agg.refresh(now: now, calendar: utc).fiveHour.output == 91)
    }
}
