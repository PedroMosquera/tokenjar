import AppKit
import Observation
import HeadroomCore

struct AccountStatus: Equatable {
    var snapshot: UsageSnapshot?
    var error: FetchError?
    var lastAttempt: Date?
    var isRefreshing = false

    /// Data older than twice the refresh interval is shown dimmed; it may no longer reflect the account.
    func isStale(now: Date, refreshMinutes: Int) -> Bool {
        guard let fetchedAt = snapshot?.fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > Double(max(refreshMinutes, 1) * 2 * 60)
    }
}

/// Single source of truth for every view. Views read it and call its actions; they never fetch on their own.
@Observable
final class AppModel {
    struct Presenter {
        var showDashboard: (String?) -> Void = { _ in }
        var showSettings: (String?) -> Void = { _ in }
        var closePopover: () -> Void = {}
    }

    var config = AppConfig()
    private(set) var baseConfig = AppConfig()
    var hasLocalOverrides = false
    var configError: String?

    /// Keyed by AccountConfig.id.
    var statuses: [String: AccountStatus] = [:]
    var isRefreshing = false
    var lastRefreshAt: Date?
    /// Ticks every 30 s so countdowns and "updated 2m ago" stay current.
    var now = Date()

    var dashboardSelection: String?
    var settingsSelection: String?

    @ObservationIgnored var presenter = Presenter()
    @ObservationIgnored let paths = AppPaths()
    @ObservationIgnored var store: (any UsageStore)?
    @ObservationIgnored var priceTable = PriceTable()
    @ObservationIgnored private var ticker: Timer?
    /// Set by `AppModel.preview()`: shows every configured account regardless of what exists on this Mac.
    @ObservationIgnored var previewMode = false

    /// Accounts to show on this Mac: enabled, and with their profile dir or credential present.
    var accounts: [AccountConfig] {
        config.accounts.filter { $0.enabled && (previewMode || AccountDiscovery.isAvailable($0, paths: paths)) }
    }

    func status(for account: AccountConfig) -> AccountStatus {
        statuses[account.id] ?? AccountStatus()
    }

    var menuBarState: MenuBarState {
        MenuBarState.make(accounts: accounts.filter(\.showInMenuBar), statuses: statuses, config: config, now: now)
    }

    // MARK: Lifecycle

    func start() {
        loadConfig()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        refresh(force: true)
    }

    func popoverWillOpen() {
        now = Date()
        if let last = lastRefreshAt, now.timeIntervalSince(last) < 120 { return }
        refresh(force: false)
    }

    func loadConfig() {
        let configStore = ConfigStore(paths: paths)
        do {
            if let loaded = try configStore.load() {
                config = loaded.merged
                baseConfig = loaded.base
                hasLocalOverrides = loaded.hasLocalOverrides
            } else {
                var fresh = AppConfig()
                fresh.accounts = AccountDiscovery.discover(paths: paths, cli: CLILocator(overrides: fresh.cliPaths))
                config = fresh
                baseConfig = fresh
                try configStore.write(fresh)
            }
            configError = nil
        } catch {
            configError = "Could not read config.json. Using defaults until it is fixed."
        }
    }

    /// Applies an edit from Settings and saves it to config.json (through the stow symlink if there is one).
    func updateConfig(_ edit: (inout AppConfig) -> Void) {
        let old = config
        var new = config
        edit(&new)
        guard new != old else { return }
        config = new
        do {
            baseConfig = try ConfigStore(paths: paths).save(old: old, new: new, base: baseConfig)
            configError = nil
        } catch {
            configError = "Could not save config.json."
        }
    }

    // MARK: Refresh

    func refresh(force: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let context = FetchContext(cli: CLILocator(overrides: config.cliPaths), paths: paths)
        let targets = accounts
        for account in targets { statuses[account.id, default: AccountStatus()].isRefreshing = true }
        Task {
            await withTaskGroup(of: (String, Result<UsageSnapshot, FetchError>).self) { group in
                for account in targets {
                    group.addTask {
                        do {
                            let snapshot = try await FetcherRegistry.fetcher(for: account.provider).fetch(account, context: context)
                            return (account.id, .success(snapshot))
                        } catch let error as FetchError {
                            return (account.id, .failure(error))
                        } catch {
                            return (account.id, .failure(.network(String(describing: type(of: error)))))
                        }
                    }
                }
                for await (id, result) in group { apply(result, to: id) }
            }
            isRefreshing = false
            lastRefreshAt = Date()
            now = Date()
        }
    }

    private func apply(_ result: Result<UsageSnapshot, FetchError>, to accountID: String) {
        var status = statuses[accountID] ?? AccountStatus()
        status.isRefreshing = false
        status.lastAttempt = Date()
        switch result {
        case .success(let snapshot):
            status.snapshot = snapshot
            status.error = nil
        case .failure(let error):
            status.error = error
        }
        statuses[accountID] = status
    }

    // MARK: History for charts

    func samples(accountID: String, windowID: String?, since: Date) -> [WindowSample] {
        (try? store?.samples(accountID: accountID, windowID: windowID, since: since)) ?? []
    }

    func pricedUsage(accountIDs: [String]?, since: Date) -> [PricedUsageRow] {
        let rows = (try? store?.dailyUsage(accountIDs: accountIDs, since: since)) ?? []
        return rows.map(priceTable.priced)
    }

    // MARK: Actions

    func openProviderDashboard(_ account: AccountConfig) {
        NSWorkspace.shared.open(account.resolvedDashboardURL)
    }

    func openStatusPage(_ account: AccountConfig) {
        if let url = account.provider.statusPageURL { NSWorkspace.shared.open(url) }
    }

    func showDashboard(accountID: String? = nil) { presenter.showDashboard(accountID) }
    func showSettings(accountID: String? = nil) { presenter.showSettings(accountID) }
    func closePopover() { presenter.closePopover() }

    func quit() { NSApp.terminate(nil) }
}
