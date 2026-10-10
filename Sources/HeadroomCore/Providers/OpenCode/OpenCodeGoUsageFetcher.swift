import Foundation

public struct OpenCodeGoUsageFetcher: UsageFetcher {
    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        throw FetchError.unsupported("OpenCode Go fetcher not implemented yet")
    }
}

public struct OpenCodeZenUsageFetcher: UsageFetcher {
    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        throw FetchError.unsupported("OpenCode Zen fetcher not implemented yet")
    }
}
