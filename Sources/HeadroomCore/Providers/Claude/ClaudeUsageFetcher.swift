import Foundation

public struct ClaudeUsageFetcher: UsageFetcher {
    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        throw FetchError.unsupported("Claude fetcher not implemented yet")
    }
}
