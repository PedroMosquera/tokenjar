import Foundation

/// Cursor shares its usage only through its own login token or a browser session, both outside Tokenjar's rules, so
/// the account is a link to the usage page. This runs no process, sends nothing and reads no file.
public struct CursorUsageFetcher: UsageFetcher {
    public static let source = "usage page"
    public static let noUsageNote = "Cursor doesn't share your usage with local apps. Open the usage page to see it."

    public init() {}

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        UsageSnapshot(accountID: account.id, provider: .cursor, fetchedAt: context.now(), source: Self.source, notes: [Self.noUsageNote])
    }
}
