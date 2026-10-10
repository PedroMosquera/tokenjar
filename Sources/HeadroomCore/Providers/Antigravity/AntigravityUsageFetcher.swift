import Foundation

public struct AntigravityUsageFetcher: UsageFetcher {
    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        throw FetchError.unsupported("Antigravity fetcher not implemented yet")
    }
}
