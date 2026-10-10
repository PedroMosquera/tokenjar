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
    /// Bumped whenever stored samples or usage rows change, so history views reload.
    var historyRevision = 0
    var notificationsAuthorized: Bool?

    var dashboardSelection: String?
    var settingsSelection: String?

    @ObservationIgnored var presenter = Presenter()
    @ObservationIgnored let paths = AppPaths()
    @ObservationIgnored var store: (any UsageStore)?
    @ObservationIgnored var priceTable = PriceTable()
    @ObservationIgnored var notifications: NotificationManager?
    /// Set by `AppModel.preview()`: shows every configured account regardless of what exists on this Mac.
    @ObservationIgnored var previewMode = false

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var alertState = AlertState()
    @ObservationIgnored private var nextDue: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var lastScanAt: Date?
    @ObservationIgnored private var configStamp: [Date?] = []

    private static let scanInterval: TimeInterval = 5 * 60

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
        signal(SIGPIPE, SIG_IGN)
        loadConfig()
        do {
            store = try SQLiteUsageStore(url: paths.databaseFile)
        } catch {
            store = nil
            configError = "History is unavailable: could not open the database."
        }
        priceTable = PriceTable.load(bundled: ProviderLogo.resourceURL("pricing.json"), override: paths.pricingOverrideFile)
        seedFromStore()
        loadAlertState()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network is usually not back the instant the lid opens.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self?.refresh(force: true)
            }
        }
        refresh(force: true)
        scanHistory()
    }

    func popoverWillOpen() {
        now = Date()
        if let last = lastRefreshAt, now.timeIntervalSince(last) < 120 { return }
        refresh(force: true)
    }

    private func tick() {
        now = Date()
        reloadConfigIfChanged()
        refresh(force: false)
        if lastScanAt.map({ now.timeIntervalSince($0) >= Self.scanInterval }) ?? true { scanHistory() }
    }

    // MARK: Config

    func loadConfig() {
        let configStore = ConfigStore(paths: paths)
        do {
            if let loaded = try configStore.load() {
                config = loaded.merged
                baseConfig = loaded.base
                hasLocalOverrides = loaded.hasLocalOverrides
            } else {
                var fresh = AppConfig()
                let discovered = AccountDiscovery.discover(paths: paths, cli: CLILocator(overrides: fresh.cliPaths))
                fresh.accounts = discovered
                if let preview = CodexBarImport.preview(paths: paths) {
                    fresh = CodexBarImport.apply(preview, to: fresh, discovered: discovered, paths: paths)
                }
                config = fresh
                baseConfig = fresh
                try configStore.write(fresh)
            }
            configError = nil
        } catch {
            configError = "Could not read config.json. Using the last good settings until it is fixed."
        }
        configStamp = currentConfigStamp()
    }

    /// Picks up edits made outside the app, e.g. a `git pull` in the dotfiles repo the config is stowed from.
    private func reloadConfigIfChanged() {
        guard !previewMode, currentConfigStamp() != configStamp else { return }
        let before = config
        loadConfig()
        if config.accounts != before.accounts { refresh(force: true) }
    }

    private func currentConfigStamp() -> [Date?] {
        [paths.configFile, paths.localConfigFile].map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        }
    }

    /// Applies an edit from Settings and saves it to config.json (through the stow symlink if there is one).
    func updateConfig(_ edit: (inout AppConfig) -> Void) {
        let old = config
        var new = config
        edit(&new)
        guard new != old else { return }
        config = new
        guard !previewMode else { return }
        do {
            baseConfig = try ConfigStore(paths: paths).save(old: old, new: new, base: baseConfig)
            configError = nil
        } catch {
            configError = "Could not save config.json."
        }
        configStamp = currentConfigStamp()
        if old.accounts != new.accounts {
            for account in new.accounts where old.accounts.first(where: { $0.id == account.id }) != account {
                nextDue[account.id] = nil
            }
            refresh(force: false)
        }
        if new.alerts.enabled, !old.alerts.enabled { requestNotificationPermission(prominent: true) }
    }

    // MARK: Refresh

    /// `force` refreshes every visible account now; otherwise only accounts whose interval has elapsed.
    func refresh(force: Bool) {
        let current = Date()
        let targets = accounts.filter { force || (nextDue[$0.id] ?? .distantPast) <= current }
        refresh(targets)
    }

    func refresh(accountID: String) {
        refresh(accounts.filter { $0.id == accountID })
    }

    private func refresh(_ targets: [AccountConfig]) {
        let targets = targets.filter { !inFlight.contains($0.id) }
        guard !targets.isEmpty, !previewMode else { return }
        for account in targets {
            inFlight.insert(account.id)
            statuses[account.id, default: AccountStatus()].isRefreshing = true
        }
        isRefreshing = true
        let context = FetchContext(cli: CLILocator(overrides: config.cliPaths), paths: paths)
        Task {
            await withTaskGroup(of: (AccountConfig, Result<UsageSnapshot, FetchError>).self) { group in
                for account in targets {
                    group.addTask {
                        do {
                            let snapshot = try await FetcherRegistry.fetcher(for: account.provider).fetch(account, context: context)
                            return (account, .success(snapshot))
                        } catch let error as FetchError {
                            return (account, .failure(error))
                        } catch {
                            return (account, .failure(.network(String(describing: type(of: error)))))
                        }
                    }
                }
                for await (account, result) in group { apply(result, to: account) }
            }
            for account in targets { inFlight.remove(account.id) }
            isRefreshing = !inFlight.isEmpty
            lastRefreshAt = Date()
            now = Date()
            historyRevision += 1
        }
    }

    private func apply(_ result: Result<UsageSnapshot, FetchError>, to account: AccountConfig) {
        let current = Date()
        var status = statuses[account.id] ?? AccountStatus()
        status.isRefreshing = false
        status.lastAttempt = current
        switch result {
        case .success(let snapshot):
            status.snapshot = snapshot
            status.error = nil
            try? store?.record(snapshot)
        case .failure(let error):
            status.error = error
        }
        statuses[account.id] = status
        nextDue[account.id] = current.addingTimeInterval(retryDelay(for: account, after: result))

        let liveAccount = config.accounts.first { $0.id == account.id } ?? account
        let outcome = AlertEngine.evaluate(account: liveAccount, result: result, config: config, state: &alertState, now: current)
        notifications?.handle(outcome)
        saveAlertState()
    }

    private func retryDelay(for account: AccountConfig, after result: Result<UsageSnapshot, FetchError>) -> TimeInterval {
        var minutes = Double(account.refreshMinutes ?? config.refreshMinutes)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { minutes = max(minutes, 30) }
        if case .failure(.rateLimited(let retryAfter)) = result {
            return max(retryAfter ?? 0, minutes * 2 * 60)
        }
        return max(1, minutes) * 60
    }

    // MARK: History

    /// Reads local harness logs incrementally off the main thread and stores per-response token counts.
    func scanHistory() {
        guard !scanning, !previewMode, let store else { return }
        scanning = true
        let jobs = accounts.compactMap { account in FetcherRegistry.scanner(for: account.provider).map { (account, $0) } }
        let paths = self.paths
        Task.detached(priority: .utility) { [weak self] in
            var changed = false
            for (account, scanner) in jobs {
                do {
                    let checkpoints = try store.checkpoints(scanner: scanner.name, accountID: account.id)
                    let result = try scanner.scan(account, checkpoints: checkpoints, paths: paths)
                    if !result.events.isEmpty {
                        try store.upsert(result.events)
                        changed = true
                    }
                    try store.saveCheckpoints(result.checkpoints, scanner: scanner.name, accountID: account.id)
                } catch {
                    // One unreadable source must not stop the others; it is retried on the next scan.
                    continue
                }
            }
            await MainActor.run { [changed] in
                guard let self else { return }
                self.scanning = false
                self.lastScanAt = Date()
                if changed { self.historyRevision += 1 }
            }
        }
    }

    func samples(accountID: String, windowID: String?, since: Date) -> [WindowSample] {
        (try? store?.samples(accountID: accountID, windowID: windowID, since: since)) ?? []
    }

    func pricedUsage(accountIDs: [String]?, since: Date) -> [PricedUsageRow] {
        let rows = (try? store?.dailyUsage(accountIDs: accountIDs, since: since)) ?? []
        return rows.map(priceTable.priced)
    }

    private func seedFromStore() {
        guard let snapshots = try? store?.latestSnapshots() else { return }
        let ids = Set(config.accounts.map(\.id))
        for snapshot in snapshots where ids.contains(snapshot.accountID) {
            statuses[snapshot.accountID, default: AccountStatus()].snapshot = snapshot
        }
    }

    // MARK: Alerts

    private var alertStateFile: URL { paths.supportDirectory.appending(path: "alert-state.json") }

    private func loadAlertState() {
        guard let data = try? Data(contentsOf: alertStateFile), let state = try? JSONDecoder().decode(AlertState.self, from: data) else { return }
        alertState = state
    }

    private func saveAlertState() {
        guard !previewMode, let data = try? JSONEncoder().encode(alertState) else { return }
        try? FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: alertStateFile, options: .atomic)
    }

    /// Without `prominent` this is the quiet provisional grant (no prompt). `prominent` shows the system prompt
    /// and is only called from an explicit user action.
    func requestNotificationPermission(prominent: Bool) {
        guard let notifications, !previewMode else { return }
        Task {
            notificationsAuthorized = await notifications.requestAuthorization(prominent: prominent)
        }
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
