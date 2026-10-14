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

    @Test func linkOnlyAccountsStayOutOfThePopoverAndTheHiddenCount() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let model = try loadedModel(home, [claude, devin]) { .success(usageSnapshot($0)) }
        await model.tick()?.value

        #expect(model.popoverAccounts.map(\.id) == ["claude"])
        #expect(model.hiddenAccounts.isEmpty)
    }

    @Test func anAccountThatNeverConnectedIsHiddenUntilACheckSucceeds() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let codex = AccountConfig(id: "codex", provider: .codex, label: "Work")
        let outcome = Outcome(.failure(.notSignedIn))
        let model = try loadedModel(home, [claude, codex], clock: clock) { account in
            account.id == "codex" ? outcome.value.map { _ in usageSnapshot(account) } : .success(usageSnapshot(account))
        }
        await model.tick()?.value
        #expect(model.popoverAccounts.map(\.id) == ["claude"])
        #expect(model.hiddenAccounts.map(\.id) == ["codex"])

        outcome.value = .success(())
        clock.advance(3600)
        await model.tick()?.value
        #expect(Set(model.popoverAccounts.map(\.id)) == ["claude", "codex"])
        #expect(model.hiddenAccounts.isEmpty)
    }

    /// A warning about an account the popover hides would point at nothing.
    @Test func aNeverConnectedAccountRaisesNoWarning() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let codex = AccountConfig(id: "codex", provider: .codex, label: "Work")
        let model = try loadedModel(home, [claude, codex]) { account in
            account.id == "codex" ? .failure(.notSignedIn) : .success(usageSnapshot(account))
        }
        await model.tick()?.value

        #expect(!model.menuBarState.showsDot)
        let summary = PopoverHeader.summary(of: model, voice: .written)
        #expect(summary.tone == .clear, "\(summary.text)")
        #expect(summary.others.isEmpty)
    }

    /// Signing out of an account that worked is news the user needs, unlike one that was never set up.
    @Test func anAccountThatWorkedStaysVisibleWhenItSignsOut() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let codex = AccountConfig(id: "codex", provider: .codex, label: "Work")
        let outcome = Outcome(.success(()))
        let model = try loadedModel(home, [codex], clock: clock) { account in outcome.value.map { _ in usageSnapshot(account) } }
        await model.tick()?.value

        outcome.value = .failure(.notSignedIn)
        clock.advance(3600)
        await model.tick()?.value
        #expect(model.status(for: codex).error == .notSignedIn)
        #expect(model.popoverAccounts.map(\.id) == ["codex"])
    }

    /// Without its CLI the account cannot connect at all, so an old snapshot is no reason to keep its card.
    @Test func anAccountWhoseCLIIsGoneIsHiddenEvenIfItWorkedBefore() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let codex = AccountConfig(id: "codex", provider: .codex, label: "ChatGPT")
        let outcome = Outcome(.success(()))
        let model = try loadedModel(home, [codex], clock: clock) { account in outcome.value.map { _ in usageSnapshot(account) } }
        await model.tick()?.value

        outcome.value = .failure(.cliNotFound("codex"))
        clock.advance(3600)
        await model.tick()?.value
        #expect(model.status(for: codex).snapshot != nil)
        #expect(model.popoverAccounts.isEmpty)
        #expect(model.hiddenAccounts.map(\.id) == ["codex"])
        #expect(!model.menuBarState.showsDot)
    }

    @Test func aConnectedAccountWithNoPlanStaysVisible() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let go = AccountConfig(id: "go", provider: .opencodeGo, label: "OpenCode Go")
        let model = try loadedModel(home, [go]) { _ in .failure(.noSubscription("No active OpenCode Go subscription for this key")) }
        await model.tick()?.value

        #expect(model.popoverAccounts.map(\.id) == ["go"])
    }

    @Test func aTurnedOffAccountCountsAsHidden() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        let off = AccountConfig(id: "off", provider: .codex, label: "Old", enabled: false)
        let model = try loadedModel(home, [claude, off]) { .success(usageSnapshot($0)) }
        await model.tick()?.value

        #expect(model.popoverAccounts.map(\.id) == ["claude"])
        #expect(model.hiddenAccounts.map(\.id) == ["off"])
    }

    private let clock = TestClock()

    private func loadedModel(
        _ home: ModelHome, _ accounts: [AccountConfig], clock: TestClock? = nil,
        result: @escaping @Sendable (AccountConfig) -> Result<UsageSnapshot, FetchError>
    ) throws -> AppModel {
        try home.writeConfig(AppConfig(accounts: accounts))
        let clock = clock ?? TestClock()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: FetchLog(), result: result) }, clock: { clock.now })
        model.isAvailable = { _ in true }
        model.loadState()
        return model
    }
}

/// A fetch result a test changes between checks; fetches read it on task-group threads.
private nonisolated final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, FetchError>

    init(_ value: Result<Void, FetchError>) { stored = value }

    var value: Result<Void, FetchError> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
