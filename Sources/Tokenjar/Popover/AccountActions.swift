import TokenjarCore

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
                AccountAction(title: "Try Once More") { model.retryProbe(accountID: account.id) },
                AccountAction(title: "Disable") { model.updateAccount(account.id) { $0.enabled = false } },
            ]
        }
        return switch error {
        case .cliNotFound: [AccountAction(title: "Set Up\u{2026}") { model.showSettings(accountID: account.id) }]
        case .notSignedIn: [AccountAction(title: "Sign In\u{2026}") { model.showSettings(accountID: account.id) }]
        case .unauthorized: [AccountAction(title: "Settings\u{2026}") { model.showSettings(accountID: account.id) }]
        case .network, .timeout, .rateLimited, .parse: [AccountAction(title: "Retry") { model.refresh(accountID: account.id) }]
        case .keychainDenied: [AccountAction(title: "Try Again") { model.refresh(accountID: account.id) }]
        case .noSubscription, .unsupported, .cliTooOld: []
        }
    }

    /// Settings' check button. A latched account is skipped by refresh(accountID:), so a plain check would do nothing.
    static func check(_ account: AccountConfig, status: AccountStatus, model: AppModel) -> AccountAction {
        if let error = status.error, ProbeLatch.spentTokens(error) {
            return AccountAction(title: "Try Once More", help: "Checks stopped because the last one spent tokens. Run one more; a repeat stops them again.") {
                model.retryProbe(accountID: account.id)
            }
        }
        if status.error == .keychainDenied {
            return AccountAction(title: "Try Again", help: "Ask macOS for the pasted key again") { model.refresh(accountID: account.id) }
        }
        return AccountAction(title: "Check Now", help: "Fetch this account's usage now") { model.refresh(accountID: account.id) }
    }
}
