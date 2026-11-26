import Foundation
import Testing

@testable import ClaudeNotchCore

struct ModelCatalogTests {
    let json =
        #"{"fetchedAt":1,"catalog":{"config":{"models":[{"id":"claude-opus-5-5","runtime":{"max_input_tokens":1000000}},"#
        + #"{"id":"claude-haiku-4-5-20251001","runtime":{"max_input_tokens":200000}},{"id":"x"}]}}}"#

    @Test func parsesWindows() throws {
        let p = try #require(ModelCatalog.parse(Data(json.utf8)))
        let c = ModelCatalog(windows: p.windows)
        #expect(c.window(for: "claude-opus-5-5") == 1_000_000)
        #expect(c.window(for: "claude-opus-5-5[1m]") == 1_000_000)
        #expect(c.window(for: "claude-haiku-4-5-20251001") == 200_000)
        #expect(c.window(for: "unknown") == nil)
    }
}
