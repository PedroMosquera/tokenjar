import Foundation

/// Devin, which now includes Windsurf (renamed Devin Desktop), has no usage source that fits Tokenjar's rules yet: its
/// web quota needs a browser session, and `devin -p /usage` is not known to answer without a model turn and would run
/// the user's Claude Code hooks and MCP servers. Until one exists the account is a link to the usage page. This runs no
/// process, sends nothing and reads no file.
public struct DevinUsageFetcher: UsageFetcher {
    public static let source = "usage page"
    public static let noQuotaNote = "Devin doesn't share your quota with local apps yet. Open the usage page to see it."
    public static let windsurfNote = "On a grandfathered Windsurf plan? Set this account's usage page to windsurf.com/subscription/manage-plan."

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id, provider: .devin, fetchedAt: context.now(), source: Self.source,
            notes: account.dashboardURL == nil ? [Self.noQuotaNote, Self.windsurfNote] : [Self.noQuotaNote]
        )
    }
}
