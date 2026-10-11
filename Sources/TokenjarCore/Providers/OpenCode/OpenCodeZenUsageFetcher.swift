import Foundation

/// OpenCode Zen has no API-key balance endpoint (the balance needs a console web session), so this reports the
/// month-to-date cost opencode recorded locally for the `opencode` provider. It makes no network request.
public struct OpenCodeZenUsageFetcher: UsageFetcher {
    static let zenProviderID = "opencode"

    let environment: [String: String]
    let calendar: Calendar

    public init() {
        self.init(environment: ProcessInfo.processInfo.environment, calendar: .current)
    }

    init(environment: [String: String], calendar: Calendar) {
        self.environment = environment
        self.calendar = calendar
    }

    public func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        let scanner = OpenCodeHistoryScanner(providerIDs: [Self.zenProviderID], environment: environment)
        guard FileManager.default.fileExists(atPath: scanner.databaseFile(for: account, paths: context.paths).path) else {
            throw FetchError.unsupported("OpenCode has not been used on this Mac")
        }
        let events: [UsageEvent]
        do {
            events = try scanner.scan(account, checkpoints: [:], paths: context.paths).events
        } catch {
            throw FetchError.unsupported("Could not read OpenCode's local database")
        }
        let now = context.now()
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let spent = events
            .filter { $0.timestamp >= monthStart && $0.timestamp <= now }
            .reduce(0) { $0 + ($1.reportedCostUSD ?? 0) }
        return UsageSnapshot(
            accountID: account.id, provider: account.provider, plan: "Pay as you go",
            money: [MoneyLine(label: "Spent this month (this Mac)", amount: spent)],
            fetchedAt: now, source: "opencode.db",
            notes: ["Balance needs a console sign-in; showing local spend only."]
        )
    }
}
