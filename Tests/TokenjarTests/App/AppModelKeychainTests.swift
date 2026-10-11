import Foundation
import Security
import Testing
@testable import Tokenjar
import TokenjarCore

/// An ad-hoc build is a new app to the Keychain, so each read of a pasted key can bring back its prompt.
@MainActor
struct AppModelKeychainTests {
    private let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .keychain(account: "go"))

    private func model(_ home: ModelHome, _ clock: TestClock, keychain: CountingSecretStore, keys: FetchLog) throws -> AppModel {
        try home.writeConfig(AppConfig(accounts: [go]))
        let model = AppModel(paths: home.paths, fetcher: { _ in PastedKeyFetcher(keys: keys) }, clock: { clock.now })
        model.secrets = SessionSecretStore(keychain)
        model.loadState()
        return model
    }

    /// Every path but the account's own check: the tick, popover open and the header button, and wake.
    private func scheduledChecks(_ model: AppModel, _ clock: TestClock) async {
        for _ in 0..<3 {
            clock.advance(10 * 60)
            await model.refresh(force: false)?.value
        }
        await model.refresh(force: true)?.value
        await model.systemDidWake(networkDelay: .zero)?.value
    }

    @Test func aDenyIsAskedAgainOnlyFromTheAccountsOwnCheck() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let keychain = CountingSecretStore(["go": "sk-placeholder"]), keys = FetchLog(), clock = TestClock()
        keychain.refuse(with: errSecAuthFailed)
        let model = try model(home, clock, keychain: keychain, keys: keys)

        await model.refresh(force: true)?.value
        #expect(model.statuses["go"]?.error == .keychainDenied)
        await scheduledChecks(model, clock)
        #expect(keychain.readCount == 1)
        #expect(model.statuses["go"]?.error == .keychainDenied)

        keychain.refuse(with: nil)
        let tryAgain = try #require(AccountAction.forError(.keychainDenied, account: go, model: model).first)
        tryAgain.run()
        try await waitUntil { keys.count("sk-placeholder") == 1 && !model.isRefreshing }
        #expect(keychain.readCount == 2)
        #expect(model.statuses["go"]?.error == nil)

        await scheduledChecks(model, clock)
        await model.refresh(accountID: "go")?.value
        #expect(keychain.readCount == 2)
        #expect(keys.count("sk-placeholder") == 7)
    }

    @Test func aSavedKeyIsCheckedAtOnceWithoutReadingItBack() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let keychain = CountingSecretStore(), keys = FetchLog(), clock = TestClock()
        keychain.refuse(with: errSecUserCanceled)
        let model = try model(home, clock, keychain: keychain, keys: keys)
        await model.refresh(force: true)?.value
        #expect(model.statuses["go"]?.error == .keychainDenied)

        try model.savePastedKey("sk-new", accountID: "go")
        try await waitUntil { keys.count("sk-new") == 1 && !model.isRefreshing }

        #expect(model.statuses["go"]?.error == nil)
        #expect(keychain.readCount == 1)
        await scheduledChecks(model, clock)
        #expect(keys.count("sk-new") == 6)
        #expect(keychain.readCount == 1)
    }
}
