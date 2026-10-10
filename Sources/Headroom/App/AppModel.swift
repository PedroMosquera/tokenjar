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
    /// The one banner the popover and Settings show: a config problem first, else a history database problem.
    var configError: String? { configProblem ?? historyProblem }
    private var configProblem: String?
    private var historyProblem: String?

    /// Keyed by AccountConfig.id.
    var statuses: [String: AccountStatus] = [:]
    var isRefreshing = false
    var lastRefreshAt: Date?
    /// Ticks every 30 s so countdowns and "updated 2m ago" stay current.
    var now = Date()
    /// Bumped whenever stored samples or usage rows change, so history views reload.
    var historyRevision = 0
    /// nil until the app has asked macOS; see `refreshNotificationPermission`.
    var notificationPermission: NotificationPermission?

    var dashboardSelection: String?
    var settingsSelection: String?

    @ObservationIgnored var presenter = Presenter()
    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored private let fetcher: (ProviderID) -> any UsageFetcher
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored var store: (any UsageStore)?
    @ObservationIgnored var priceTable = PriceTable()
    @ObservationIgnored var notifications: NotificationManager?
    /// Set by `AppModel.preview()`: shows every configured account regardless of what exists on this Mac.
    @ObservationIgnored var previewMode = false

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var alertState = AlertState()
    @ObservationIgnored private var scheduler = RefreshScheduler()
    @ObservationIgnored private var probeLatch = ProbeLatch()
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var lastScanAt: Date?
    @ObservationIgnored private var configStamp: [Date?] = []
    /// config.json or config.local.json did not load. Saving would overwrite whatever is in the file, which may be a
    /// merge conflict or a hand edit in progress, so nothing is saved until a load succeeds.
    @ObservationIgnored private var configLoadFailed = false
    @ObservationIgnored private var hasLoadedConfig = false

    /// `paths`, `fetcher` and `clock` are seams for tests; the app uses the defaults.
    init(paths: AppPaths = AppPaths(), fetcher: @escaping (ProviderID) -> any UsageFetcher = FetcherRegistry.fetcher(for:), clock: @escaping () -> Date = { Date() }) {
        self.paths = paths
        self.fetcher = fetcher
        self.clock = clock
    }

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
        loadState()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.systemDidWake() }
            },
        ]
        refresh(force: true)
        scanHistory()
    }

    /// Everything `start` reads from disk, without timers or observers.
    func loadState() {
        loadConfig(firstRunAllowed: true)
        do {
            store = try SQLiteUsageStore(url: paths.databaseFile)
            historyProblem = nil
        } catch {
            store = nil
            historyProblem = "History is unavailable: could not open the database."
        }
        priceTable = PriceTable.load(bundled: ProviderLogo.resourceURL("pricing.json"), override: paths.pricingOverrideFile)
        seedFromStore()
        loadAlertState()
        loadProbeLatch()
    }

    func popoverWillOpen() {
        now = clock()
        guard RefreshScheduler.shouldRefreshOnPopoverOpen(lastRefreshAt: lastRefreshAt, now: now) else { return }
        refresh(force: true)
    }

    @discardableResult
    func tick() -> Task<Void, Never>? {
        now = clock()
        guard !sleeping else { return nil }
        reloadConfigIfChanged()
        let fetches = refresh(force: false)
        if RefreshScheduler.shouldScan(lastScanAt: lastScanAt, now: now) { scanHistory() }
        return fetches
    }

    /// Ticks pause from sleep until the delayed wake refresh. A tick in the first seconds after wake would fetch
    /// every overdue account before the network is back, and that failure would hold for a full interval.
    func systemWillSleep() {
        sleeping = true
    }

    @discardableResult
    func systemDidWake(networkDelay: Duration = .seconds(8)) async -> Task<Void, Never>? {
        try? await Task.sleep(for: networkDelay)
        sleeping = false
        return refresh(force: true)
    }

    // MARK: Config

    /// Only `start` passes `firstRunAllowed`: discovery then writes a new config.json, and only when nothing at all,
    /// not even a dangling stow link, is at its path. A reload never writes, so a config.json missing for a moment
    /// (a branch switch in the dotfiles repo) keeps the current settings instead of replacing the user's.
    func loadConfig(firstRunAllowed: Bool = false) {
        let configStore = ConfigStore(paths: paths)
        defer { configStamp = currentConfigStamp() }
        do {
            if let loaded = try configStore.load() {
                config = loaded.merged
                baseConfig = loaded.base
                hasLocalOverrides = loaded.hasLocalOverrides
                configLoaded()
            } else if firstRunAllowed, !configPathIsTaken {
                // CodexBar's settings are imported only from Settings > General, which shows the changes first.
                var fresh = AppConfig()
                fresh.accounts = AccountDiscovery.discover(paths: paths, cli: cliLocator(for: fresh))
                config = fresh
                baseConfig = fresh
                configLoaded()
                do { try configStore.write(fresh) } catch { configProblem = "Could not create config.json." }
            } else {
                configLoadFailed = true
                configProblem = "config.json is missing or its link is broken. Keeping the current settings and saving nothing until it is back."
            }
        } catch {
            configLoadFailed = true
            configProblem = loadFailureMessage(error)
        }
    }

    private func configLoaded() {
        configLoadFailed = false
        hasLoadedConfig = true
        configProblem = nil
    }

    private func loadFailureMessage(_ error: Error) -> String {
        var file = "config.json or config.local.json"
        if case ConfigError.invalidJSON(let name, _) = error { file = name }
        let fallback = hasLoadedConfig ? "Using the last good settings" : "No settings are loaded"
        return "Could not read \(file). \(fallback), and nothing is saved until it is fixed and reloaded."
    }

    /// lstat, not stat: a stow link whose target is gone still takes the path.
    private var configPathIsTaken: Bool {
        (try? FileManager.default.attributesOfItem(atPath: paths.configFile.path)) != nil
    }

    /// Picks up edits made outside the app, e.g. a `git pull` in the dotfiles repo the config is stowed from.
    private func reloadConfigIfChanged() {
        guard !previewMode, currentConfigStamp() != configStamp else { return }
        let before = config.accounts
        loadConfig()
        refreshEditedAccounts(from: before)
    }

    private func currentConfigStamp() -> [Date?] {
        [paths.configFile, paths.localConfigFile].map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        }
    }

    /// Applies an edit from Settings and saves it to config.json (through the stow symlink if there is one).
    /// While the last load failed, the edit is neither applied nor saved; the banner says why.
    func updateConfig(_ edit: (inout AppConfig) -> Void) {
        // An outside change since the last tick is the base of this edit, or saving would revert it.
        reloadConfigIfChanged()
        guard previewMode || !configLoadFailed else { return }
        let old = config
        var new = config
        edit(&new)
        guard new != old else { return }
        config = new
        guard !previewMode else { return }
        do {
            baseConfig = try ConfigStore(paths: paths).save(old: old, new: new, base: baseConfig)
            configProblem = nil
        } catch {
            configProblem = "Could not save config.json."
        }
        configStamp = currentConfigStamp()
        refreshEditedAccounts(from: old.accounts)
        // Quiet grant only: the Alerts pane's "Allow banners" is the one place the system prompt appears.
        if new.alerts.enabled, !old.alerts.enabled { requestNotificationPermission(prominent: false) }
    }

    private func refreshEditedAccounts(from old: [AccountConfig]) {
        guard config.accounts != old else { return }
        scheduler.invalidate(config.accounts.filter { !old.contains($0) }.map(\.id))
        refresh(force: false)
    }

    // MARK: Refresh

    /// `force` skips the refresh interval (popover open, wake, the header button) but not a rate-limit backoff.
    @discardableResult
    func refresh(force: Bool) -> Task<Void, Never>? {
        let due = Set(scheduler.due(accounts.map(\.id), now: clock(), force: force))
        return fetch(accounts.filter { due.contains($0.id) })
    }

    /// An explicit per-account check, such as Settings > Test: it overrides the interval and a rate-limit backoff.
    @discardableResult
    func refresh(accountID: String) -> Task<Void, Never>? {
        fetch(accounts.filter { $0.id == accountID && !scheduler.inFlight.contains($0.id) })
    }

    /// The one way to probe an account again after its probe spent tokens or quota: one run, latched again if it
    /// repeats.
    @discardableResult
    func retryProbe(accountID: String) -> Task<Void, Never>? {
        if probeLatch.release(accountID) { saveProbeLatch() }
        return refresh(accountID: accountID)
    }

    private func fetch(_ targets: [AccountConfig]) -> Task<Void, Never>? {
        guard !previewMode else { return nil }
        let targets = withoutLatchedProbes(targets)
        guard !targets.isEmpty else { return nil }
        scheduler.begin(targets.map(\.id))
        for account in targets {
            statuses[account.id, default: AccountStatus()].isRefreshing = true
        }
        isRefreshing = true
        let context = FetchContext(cli: cliLocator(for: config), paths: paths)
        let jobs = targets.map { ($0, fetcher($0.provider)) }
        return Task {
            var dropped = false
            await withTaskGroup(of: (AccountConfig, Result<UsageSnapshot, FetchError>).self) { group in
                for (account, fetcher) in jobs {
                    group.addTask {
                        do {
                            let snapshot = try await fetcher.fetch(account, context: context)
                            return (account, .success(snapshot))
                        } catch let error as FetchError {
                            return (account, .failure(error))
                        } catch {
                            return (account, .failure(.network(String(describing: type(of: error)))))
                        }
                    }
                }
                for await (account, result) in group {
                    if !apply(result, to: account) { dropped = true }
                    isRefreshing = !scheduler.inFlight.isEmpty
                }
            }
            lastRefreshAt = clock()
            now = clock()
            historyRevision += 1
            if dropped { refresh(force: false) }
        }
    }

    /// Returns false when the account was edited, disabled or removed while its fetch ran. Such a result describes
    /// the old settings, so it is not shown, stored or alerted on, and the account is due again at once.
    private func apply(_ result: Result<UsageSnapshot, FetchError>, to account: AccountConfig) -> Bool {
        let current = clock()
        var modelTurn: ProbeLatch.CLI?, rateLimited = false
        if case .failure(let error) = result {
            modelTurn = ProbeLatch.CLI(modelTurn: error)
            if case .rateLimited = error { rateLimited = true }
        }
        let live = config.accounts.first { $0.id == account.id }
        // A model turn has already spent tokens or quota whatever changed meanwhile, so it always latches.
        guard live == account || modelTurn != nil else {
            scheduler.finish(account.id, at: current, delay: nil, rateLimited: false)
            statuses[account.id]?.isRefreshing = false
            return false
        }

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
        let delay = RefreshScheduler.retryDelay(
            accountMinutes: account.refreshMinutes, globalMinutes: config.refreshMinutes,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, result: result
        )
        scheduler.finish(account.id, at: current, delay: delay, rateLimited: rateLimited)
        if let modelTurn {
            probeLatch.latch(account.id, cli: modelTurn, binary: ProbeLatch.fingerprint(ofBinaryAt: cliLocator(for: config).locate(modelTurn.rawValue)))
            saveProbeLatch()
        }

        let outcome = AlertEngine.evaluate(account: live ?? account, result: result, config: config, state: &alertState, now: current)
        notifications?.handle(outcome)
        saveAlertState()
        return true
    }

    /// Accounts whose last probe spent tokens or quota stay out, unless the binary of the CLI that ran it has changed.
    private func withoutLatchedProbes(_ targets: [AccountConfig]) -> [AccountConfig] {
        guard !probeLatch.isEmpty else { return targets }
        let locator = cliLocator(for: config)
        if probeLatch.releaseAll(unlessBinary: { ProbeLatch.fingerprint(ofBinaryAt: locator.locate($0.rawValue)) }) { saveProbeLatch() }
        return targets.filter { !probeLatch.isLatched($0.id) }
    }

    private func cliLocator(for config: AppConfig) -> CLILocator {
        CLILocator(home: paths.home, overrides: config.cliPaths)
    }

    // MARK: History

    /// Reads local harness logs incrementally off the main thread and stores per-response token counts.
    func scanHistory() {
        guard !scanning, !previewMode, let store else { return }
        scanning = true
        let jobs = accounts.compactMap { account in FetcherRegistry.scanner(for: account.provider).map { (account, $0) } }
        let paths = self.paths
        Task.detached(priority: .utility) { [weak self] in
            let changed = HistoryScanJob.run(jobs, store: store, paths: paths)
            await MainActor.run {
                guard let self else { return }
                self.scanning = false
                self.lastScanAt = self.clock()
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

    // MARK: Persisted state

    private var alertStateFile: URL { paths.supportDirectory.appending(path: "alert-state.json") }
    private var probeLatchFile: URL { paths.supportDirectory.appending(path: "probe-latch.json") }

    private func loadAlertState() {
        guard let data = try? Data(contentsOf: alertStateFile), let state = try? JSONDecoder().decode(AlertState.self, from: data) else { return }
        alertState = state
    }

    private func saveAlertState() {
        guard !previewMode, let data = try? JSONEncoder().encode(alertState) else { return }
        writeOwnerOnly(data, to: alertStateFile)
    }

    private func loadProbeLatch() {
        guard let data = try? Data(contentsOf: probeLatchFile), let latch = try? JSONDecoder().decode(ProbeLatch.self, from: data) else { return }
        probeLatch = latch
        // Nothing probes a latched account, so without this its card would not say why it stopped updating.
        for id in latch.accountIDs {
            statuses[id, default: AccountStatus()].error = latch.cli(of: id)?.modelTurnError
        }
    }

    private func saveProbeLatch() {
        guard !previewMode, let data = try? JSONEncoder().encode(probeLatch) else { return }
        writeOwnerOnly(data, to: probeLatchFile)
    }

    /// A new file lands at the umask's 0644 until the chmod; later atomic rewrites keep 0600. The 0700 folder covers that first moment.
    private func writeOwnerOnly(_ data: Data, to file: URL) {
        try? AppPaths.createOwnerOnlyDirectory(file.deletingLastPathComponent())
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Notifications

    /// Without `prominent` this is the quiet provisional grant (no prompt). `prominent` shows the system prompt
    /// and is only called from an explicit user action.
    func requestNotificationPermission(prominent: Bool) {
        guard let notifications, !previewMode else { return }
        Task {
            notificationPermission = await notifications.requestAuthorization(prominent: prominent)
        }
    }

    /// Reads the current grant without asking, so Settings can show whether alerts arrive as banners or quietly.
    func refreshNotificationPermission() {
        guard let notifications, !previewMode else { return }
        Task {
            notificationPermission = await notifications.permission()
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
