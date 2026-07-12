import Foundation

/// Per-model token prices (USD per million tokens). On subscription plans there's
/// no per-token bill, so these produce an *equivalent API cost* — useful for
/// comparing intensity across repos/models even when you're on a flat plan.
/// Approximate Anthropic list prices; adjust if they drift.
public struct ModelPrice: Sendable, Hashable {
    public var input: Double        // per 1M input tokens
    public var output: Double       // per 1M output tokens
    public var cacheWrite: Double   // per 1M cache-creation tokens
    public var cacheRead: Double    // per 1M cache-read tokens

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }
}

public enum Pricing {
    // Keyed by a substring of the model id (e.g. "claude-opus-4-8").
    static let table: [(match: String, price: ModelPrice)] = [
        ("opus",   ModelPrice(input: 15,  output: 75, cacheWrite: 18.75, cacheRead: 1.50)),
        ("sonnet", ModelPrice(input: 3,   output: 15, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  ModelPrice(input: 1.0, output: 5,  cacheWrite: 1.25,  cacheRead: 0.10)),
        ("fable",  ModelPrice(input: 1.0, output: 5,  cacheWrite: 1.25,  cacheRead: 0.10)),
    ]
    static let fallback = ModelPrice(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30) // sonnet-ish

    public static func price(for model: String?) -> ModelPrice {
        guard let m = model?.lowercased() else { return fallback }
        return table.first { m.contains($0.match) }?.price ?? fallback
    }

    /// Equivalent USD for one message's token usage.
    public static func cost(model: String?, input: Int, output: Int,
                            cacheCreation: Int, cacheRead: Int) -> Double {
        let p = price(for: model)
        return (Double(input) * p.input
                + Double(output) * p.output
                + Double(cacheCreation) * p.cacheWrite
                + Double(cacheRead) * p.cacheRead) / 1_000_000
    }
}
