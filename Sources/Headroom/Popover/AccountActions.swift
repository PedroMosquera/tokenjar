import HeadroomCore

/// A button offered for one account's state, shared by the popover card and Settings.
/// Every check it starts is for that account alone: a forced refresh of all would recheck healthy accounts and
/// still wait out a rate-limit backoff.
struct AccountAction {
    var title: String
    var help: String?
    var run: () -> Void

    static func forError(_ error: FetchError, account: AccountConfig, model: AppModel) -> [AccountAction] {
        if ProbeLatch.spentTokens(error) {
            return [
                AccountAction(title: "Try once more") { model.retryProbe(accountID: account.id) },
                AccountAction(title: "Disable") { model.updateAccount(account.id) { $0.enabled = false } },
            ]
        }
        return switch error {
        case .cliNotFound: [AccountAction(title: "Setup") { model.showSettings(accountID: account.id) }]
        case .notSignedIn: [AccountAction(title: "Sign in") { model.showSettings(accountID: account.id) }]
        case .unauthorized: [AccountAction(title: "Settings") { model.showSettings(accountID: account.id) }]
        case .network, .timeout, .rateLimited, .parse: [AccountAction(title: "Retry") { model.refresh(accountID: account.id) }]
        case .noSubscription, .unsupported: []
        }
    }

    /// Settings' check button. A latched account is skipped by refresh(accountID:), so a plain Test would do nothing.
    static func check(_ account: AccountConfig, status: AccountStatus, model: AppModel) -> AccountAction {
        if let error = status.error, ProbeLatch.spentTokens(error) {
            return AccountAction(title: "Try Once More", help: "Checks stopped because the last one spent tokens. Run one more; a repeat stops them again.") {
                model.retryProbe(accountID: account.id)
            }
        }
        return AccountAction(title: "Test", help: "Fetch this account's usage now") { model.refresh(accountID: account.id) }
    }
}
