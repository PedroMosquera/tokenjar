import Foundation

public struct CodexUsageFetcher: UsageFetcher {
    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        throw FetchError.unsupported("Codex fetcher not implemented yet")
    }
}
