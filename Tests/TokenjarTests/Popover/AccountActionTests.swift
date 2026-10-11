import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct AccountActionTests {
    private let modelTurn = FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "ChatGPT")

    private func model(_ home: ModelHome, accounts: [AccountConfig], log: FetchLog, result: @escaping @Sendable (AccountConfig) -> Result<UsageSnapshot, FetchError>) throws -> AppModel {
        try home.makeDirectory(".claude")
        try home.makeDirectory(".codex")
        try home.writeConfig(AppConfig(accounts: accounts))
        let clock = TestClock()
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: log, result: result) }, clock: { clock.now })
        model.loadState()
        return model
    }

    private func action(_ title: String, in actions: [AccountAction]) throws -> AccountAction {
        try #require(actions.first { $0.title == title }, "no \(title) in \(actions.map(\.title))")
    }

    @Test func retryChecksOnlyTheFailingAccount() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let log = FetchLog()
        let model = try model(home, accounts: [claude, codex], log: log) { account in
            account.provider == .claude ? .failure(.network("offline")) : .success(usageSnapshot(account))
        }
        await model.refresh(force: true)?.value
        #expect(log.count("claude") == 1)
        #expect(log.count("codex") == 1)

        try action("Retry", in: AccountAction.forError(.network("offline"), account: claude, model: model)).run()
        try await waitUntil { log.count("claude") == 2 && !model.isRefreshing }
        #expect(log.count("codex") == 1)
    }

    @Test func aProbeThatSpentTokensOffersOneMoreTryOrDisable() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let log = FetchLog()
        let model = try model(home, accounts: [claude], log: log) { [modelTurn] _ in .failure(modelTurn) }
        await model.refresh(force: true)?.value
        await model.refresh(accountID: "claude")?.value
        #expect(log.count("claude") == 1)

        let actions = AccountAction.forError(modelTurn, account: claude, model: model)
        #expect(actions.map(\.title) == ["Try Once More", "Disable"])
        try action("Try Once More", in: actions).run()
        try await waitUntil { log.count("claude") == 2 && !model.isRefreshing }

        try action("Disable", in: actions).run()
        #expect(model.config.accounts.first?.enabled == false)
        #expect(try home.readConfig().accounts.first?.enabled == false)
    }

    @Test func problemsARetryCannotFixOfferNothing() {
        let model = AppModel.preview()
        #expect(AccountAction.forError(.unsupported("agy 1.0 is too old"), account: claude, model: model).isEmpty)
        #expect(AccountAction.forError(.noSubscription("No active OpenCode Go subscription"), account: claude, model: model).isEmpty)
    }

    /// Title case, and an ellipsis on a button that opens a window where the user still has to act.
    @Test func buttonTitlesFollowTheMacConventions() {
        let model = AppModel.preview()
        func titles(_ error: FetchError) -> [String] { AccountAction.forError(error, account: claude, model: model).map(\.title) }
        #expect(titles(.cliNotFound("claude")) == ["Set Up\u{2026}"])
        #expect(titles(.notSignedIn) == ["Sign In\u{2026}"])
        #expect(titles(.unauthorized) == ["Settings\u{2026}"])
        #expect(titles(.network("offline")) == ["Retry"])
        #expect(titles(modelTurn) == ["Try Once More", "Disable"])
        let check = AccountAction.check(claude, status: AccountStatus(), model: model)
        #expect(check.title == "Check Now")
        #expect(check.help == "Fetch this account's usage now")
    }

    /// The latch blocks refresh(accountID:), so a plain check would silently do nothing.
    @Test func settingsOffersOneMoreTryInsteadOfCheckNowForALatchedAccount() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let log = FetchLog()
        let model = try model(home, accounts: [claude], log: log) { [modelTurn] _ in .failure(modelTurn) }
        #expect(AccountAction.check(claude, status: model.status(for: claude), model: model).title == "Check Now")
        await model.refresh(force: true)?.value

        let check = AccountAction.check(claude, status: model.status(for: claude), model: model)
        #expect(check.title == "Try Once More")
        check.run()
        try await waitUntil { log.count("claude") == 2 && !model.isRefreshing }
    }
}

struct MoneyRowTests {
    private let us = Locale(identifier: "en_US")

    @Test func anAmountAndItsLimitShareOnePrecision() {
        #expect(MoneyRow.amount(MoneyLine(label: "Extra usage", amount: 12.4, limit: 100), locale: us) == "$12.40 used of $100.00")
        #expect(MoneyRow.amount(MoneyLine(label: "Spent", amount: 12.4), locale: us) == "$12.40")
    }
}

struct AlertDeliveryTests {
    @Test func quietOrUnaskedOffersBanners() {
        for permission in [NotificationPermission.quiet, .notDetermined] {
            let delivery = AlertDelivery(permission)
            #expect(delivery.summary.contains("quietly in Notification Center"))
            #expect(delivery.action == .allowBanners)
        }
    }

    @Test func deniedPointsToSystemSettings() {
        #expect(AlertDelivery(.denied).action == .openNotificationSettings)
    }

    /// Allow Banners shows the system prompt, so it is offered only while banners are still missing.
    @Test func noPromptWhenBannersAreOnOrMacOSCannotBeAsked() {
        #expect(AlertDelivery(.banners).action == nil)
        #expect(AlertDelivery(.unavailable).action == nil)
        #expect(AlertDelivery(.unavailable).summary.contains("~/Applications"))
        #expect(AlertDelivery(nil).action == nil)
    }

    @Test func notificationSettingsOpenOnThisApp() {
        #expect(AlertDelivery.notificationSettingsURL(bundleID: "dev.example.tokenjar").absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.example.tokenjar")
        #expect(AlertDelivery.notificationSettingsURL(bundleID: nil).absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
