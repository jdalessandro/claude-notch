import Foundation

public struct TokenUsage: Sendable, Equatable, Codable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public var total: Int { input + output + cacheRead + cacheWrite }
    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        .init(
            input: a.input + b.input, output: a.output + b.output,
            cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

/// USD per million tokens. These are *estimates* keyed by model family; override via
/// `~/Library/Application Support/Notchbot/pricing.json` (see docs/ARCHITECTURE.md).
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double, output: Double, cacheRead: Double, cacheWrite: Double
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct PriceTable: Codable, Sendable, Equatable {
    /// Substring of the model id (lowercased) -> price. First match wins, in `order`.
    public var families: [String: ModelPrice]
    public var order: [String]
    public var fallback: ModelPrice

    public static let `default` = PriceTable(
        families: [
            "opus": .init(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
            "sonnet": .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
            "haiku": .init(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        ],
        order: ["opus", "sonnet", "haiku"],
        fallback: .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75))

    public func price(for model: String?) -> ModelPrice {
        let m = (model ?? "").lowercased()
        for key in order where m.contains(key) { if let p = families[key] { return p } }
        return fallback
    }

    public func cost(_ u: TokenUsage, model: String?) -> Double {
        let p = price(for: model)
        return
            (Double(u.input) * p.input + Double(u.output) * p.output
            + Double(u.cacheRead) * p.cacheRead + Double(u.cacheWrite) * p.cacheWrite) / 1_000_000
    }

    public static func load(from url: URL) -> PriceTable {
        guard let d = try? Data(contentsOf: url),
            let t = try? JSONDecoder().decode(PriceTable.self, from: d)
        else { return .default }
        return t
    }
}
