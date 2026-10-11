import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AppModelAccountsTests {
    /// Every view reads `accounts`, often several times per render; each read used to stat every account's folder.
    @Test func accountsAreCheckedOncePerTickNotOnEveryRead() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeDirectory(".claude")
        let personal = AccountConfig(id: "personal", provider: .claude, label: "Personal")
        let work = AccountConfig(id: "work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
        try home.writeConfig(AppConfig(accounts: [personal, work]))
        let log = FetchLog(), clock = TestClock()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log) { .success(usageSnapshot($0)) } }, clock: { clock.now })
        var checks = 0
        model.isAvailable = { account in
            checks += 1
            return AccountDiscovery.isAvailable(account, paths: home.paths)
        }
        model.loadState()
        #expect(model.accounts.map(\.id) == ["personal"])

        checks = 0
        await model.tick()?.value
        for _ in 0..<50 { _ = model.accounts }
        #expect(checks == 2)

        try home.makeDirectory(".claude-work")
        clock.advance(30)
        await model.tick()?.value
        #expect(model.accounts.map(\.id) == ["personal", "work"])
    }
}
