import Foundation

/// The input a model processed, split by where it came from. Every scanner stores `inputTokens` without the cached part:
/// Claude's `input_tokens` already leaves it out, the Codex scanner subtracts codex's cached and cache-write input, and
/// opencode records its non-cached count. So the whole prompt is the sum of the three fields for every harness.
public struct PromptTokens: Equatable, Sendable {
    public var uncached = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(uncached: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.uncached = uncached
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public mutating func add(_ event: UsageEvent) {
        uncached += event.inputTokens
        cacheRead += event.cacheReadTokens
        cacheWrite += event.cacheWrite5mTokens + event.cacheWrite1hTokens
    }

    public mutating func add(_ row: DailyUsageRow) {
        uncached += row.inputTokens
        cacheRead += row.cacheReadTokens
        cacheWrite += row.cacheWrite5mTokens + row.cacheWrite1hTokens
    }

    public static func + (a: PromptTokens, b: PromptTokens) -> PromptTokens {
        PromptTokens(uncached: a.uncached + b.uncached, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    /// Nothing read from or written to cache means the source reports no cache data, which is not a 0 % hit rate.
    public var reportsCache: Bool { cacheRead + cacheWrite > 0 }

    /// Cache reads as a share of the whole prompt, 0...1; nil without cache data.
    public var cacheHitRate: Double? {
        guard reportsCache else { return nil }
        return Double(cacheRead) / Double(uncached + cacheRead + cacheWrite)
    }
}
