import Foundation
import Testing

@testable import NotchbotCore

@Suite struct Transcript {
    @Test func dedupesStreamedRequestsAndReadsCost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).jsonl")
        func a(_ rid: String, out: Int, side: Bool = false) -> String {
            #"{"type":"assistant","requestId":"\#(rid)","isSidechain":\#(side),"message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":\#(out),"cache_read_input_tokens":100,"cache_creation_input_tokens":10}}}"#
        }
        let lines = [
            a("r1", out: 5), a("r1", out: 50), a("r2", out: 20), a("r3", out: 999, side: true),
            #"{"type":"ai-title","aiTitle":"Fix it"}"#,
            #"{"type":"cost-state","totalCostUSD":1.25,"totalLinesAdded":7,"totalLinesRemoved":2}"#,
        ]
        try (lines.joined(separator: "\n") + "\n" + #"{"type":"assistant","requestId":"r4","mess"#).write(
            to: url, atomically: true, encoding: .utf8)
        let t = TranscriptTailer(url: url)
        var snap = t.poll()
        #expect(snap.requestCount == 3)  // r4 is a partial line, ignored
        #expect(snap.usage.output == 50 + 20 + 999)
        #expect(snap.contextTokens == 112)  // sidechain r3 excluded from context
        #expect(snap.title == "Fix it")
        #expect(snap.reportedCostUSD == 1.25 && snap.linesAdded == 7)
        // Complete the partial line; next poll picks it up incrementally.
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd()
        try h.write(contentsOf: Data((#"age":{"usage":{"input_tokens":1,"output_tokens":3}}}"# + "\n").utf8)); try h.close()
        snap = t.poll()
        #expect(snap.requestCount == 4)
    }

    @Test func costEstimate() {
        let c = PriceTable.default.cost(TokenUsage(input: 1_000_000, output: 1_000_000), model: "claude-sonnet-5-5")
        #expect(c == 18)
    }
}

@Suite struct TranscriptRotation {
    @Test func replacedLargerTranscriptIsDetectedByInode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID()).jsonl")
        func a(_ rid: String, _ out: Int) -> String {
            #"{"type":"assistant","requestId":"\#(rid)","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"#
        }
        try (a("r1", 5) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let t = TranscriptTailer(url: url)
        #expect(t.poll().usage.output == 5)
        try FileManager.default.removeItem(at: url)  // replaced by a different, larger file
        try [a("n1", 10), a("n2", 20), a("n3", 30)].joined(separator: "\n").appending("\n").write(
            to: url, atomically: true, encoding: .utf8)
        let snap = t.poll()
        #expect(snap.requestCount == 3 && snap.usage.output == 60)  // not 65: the old file's request is gone
    }
}
