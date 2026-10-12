import AppKit
import Observation
import os
import TokenjarCore

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

    /// The network error or timeout behind the latest check this launch, whether the card shows it as an error or shows a
    /// saved copy because of it. A saved copy maps to `.network("saved copy")` or `.timeout`, so every surface reads
    /// this one property.
    var connectionFailure: FetchError? {
        if let error {
            switch error {
            case .network, .timeout: return error
            default: return nil
            }
        }
        // The store's snapshot at launch may be a saved copy from an earlier launch, which says nothing about now.
        guard lastAttempt != nil else { return nil }
        switch snapshot?.liveCheckFailure {
        case .network: return .network("saved copy")
        case .timeout: return .timeout
        case .other, nil: return nil
        }
    }

    /// The latest check this launch got the provider's own answer, not a saved copy.
    var hasLiveAnswer: Bool {
        lastAttempt != nil && error == nil && snapshot != nil && snapshot?.liveCheckFailure == nil
    }
}

/// What the banner says about config.json or config.local.json, for the surfaces that need more than its text.
struct SettingsProblem: Equatable {
    var message: String
    /// "config.json" or "config.local.json" when a file is at fault; nil for the Headroom move.
    var file: String?
    /// No settings loaded at all this launch, so no account can be checked.
    var nothingLoaded: Bool
}

/// Single source of truth for every view. Views read it and call its actions; they never fetch on their own.
@Observable
final class AppModel {
    struct Presenter {
        var showDashboard: (String?) -> Void = { _ in }
        var showSettings: (String?) -> Void = { _ in }
        var closePopover: () -> Void = {}
    }

    var config = AppConfig() {
        didSet { refreshAccounts() }
    }
    private(set) var baseConfig = AppConfig()
    var hasLocalOverrides = false
    /// The one banner the popover and Settings show: a config problem first, else a history database problem.
    var configError: String? { configProblem ?? historyProblem }
    private var configProblem: String?
    private var configProblemFile: String?
    private var historyProblem: String?
    var settingsProblem: SettingsProblem? {
        configProblem.map { SettingsProblem(message: $0, file: configProblemFile, nothingLoaded: !hasLoadedConfig) }
    }

    /// False while the last load of config.json or config.local.json failed: an edit is then neither applied nor
    /// saved, so Settings should not offer one.
    var canEditConfig: Bool { !configLoadFailed }

    /// Keyed by AccountConfig.id.
    var statuses: [String: AccountStatus] = [:]
    var isRefreshing = false
    /// When the last batch of checks ended, failed or not. Only the popover-open rule reads it; every surface that says
    /// "Updated" reads `lastUpdated`.
    var lastRefreshAt: Date?
    /// Settable so previews can show each cause; the app recomputes it after every path report, settle and fetch.
    var connectivity: Connectivity = .online
    /// Ticks every 30 s so countdowns and "updated 2m ago" stay current.
    var now: Date
    /// `now` for the popover's views. It moves only while the popover is shown, so the popover's long-lived content
    /// does not redraw every 30 seconds while closed; opening it brings the clock up to date first.
    var popoverNow: Date
    /// The tallest the popover may be under its status item, set as it opens. nil leaves only the cards' own cap.
    var popoverMaxHeight: CGFloat?
    /// Set by the popover's delegate.
    @ObservationIgnored var isPopoverShown = false
    /// Bumped whenever stored samples or usage rows change, and when the local day turns over, so history views reload.
    var historyRevision = 0
    /// The local day of the last tick. History views total "today" from their last reload, and an idle account stores
    /// no sample to trigger one after midnight.
    @ObservationIgnored private var historyDay: Date
    /// nil until the app has asked macOS; see `refreshNotificationPermission`.
    var notificationPermission: NotificationPermission?

    var dashboardSelection: String?
    var settingsSelection: String?

    @ObservationIgnored var presenter = Presenter()
    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored private let fetcher: (ProviderID) -> any UsageFetcher
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let network: any NetworkStatus
    @ObservationIgnored private var networkWatch = NetworkWatch()
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastBackOnlineRefresh: Date?
    @ObservationIgnored private var firstPathWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var store: (any UsageStore)?
    @ObservationIgnored var priceTable = PriceTable()
    @ObservationIgnored var notifications: NotificationManager?
    /// Set by `AppModel.preview()`: shows every configured account regardless of what exists on this Mac.
    @ObservationIgnored var previewMode = false {
        didSet { refreshAccounts() }
    }
    /// Whether what an account reads exists on this Mac. Tests replace it.
    @ObservationIgnored var isAvailable: (AccountConfig) -> Bool
    /// Set by `loadReadOnly`: this Mac's settings and history, shown without saving, fetching, scanning or asking macOS.
    @ObservationIgnored private(set) var readOnly = false
    /// What General shows for launch at login. Window renders replace it so they never ask macOS.
    @ObservationIgnored var launchAtLoginState: () -> LaunchAtLogin.State = { LaunchAtLogin.state }
    /// Pasted API keys, held for the launch so the Keychain is asked once per account. Window renders replace it with
    /// one backed by memory, so they never reach the Keychain.
    @ObservationIgnored var secrets = SessionSecretStore(KeychainSecretStore())
    /// Asked once per launch by the Headroom move; tests replace it.
    @ObservationIgnored var legacyAppIsRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.legacyBundleIdentifier).isEmpty
            || LegacyMigration.isProcessRunning(named: LegacyMigration.legacyProcessName)
    }

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
    private var configLoadFailed = false
    private var hasLoadedConfig = false
    /// Headroom's data is still under its old names. Nothing loads for the rest of this launch: a config, database or
    /// alert state written under Tokenjar's names would take them, and the move never runs onto a taken name.
    @ObservationIgnored private var waitingForLegacyMove = false

    /// `paths`, `fetcher`, `clock` and `network` are seams for tests; the app uses the defaults. Only `start` starts the
    /// network monitor, so previews, renders, developer flags and tests never run one.
    init(
        paths: AppPaths = AppPaths(), fetcher: @escaping (ProviderID) -> any UsageFetcher = FetcherRegistry.fetcher(for:),
        clock: @escaping () -> Date = { Date() }, network: any NetworkStatus = PathMonitorNetworkStatus()
    ) {
        self.paths = paths
        self.fetcher = fetcher
        self.clock = clock
        self.network = network
        let start = clock()
        now = start
        popoverNow = start
        historyDay = Calendar.current.startOfDay(for: start)
        isAvailable = { AccountDiscovery.isAvailable($0, paths: paths) }
    }

    /// Accounts to show on this Mac: enabled, and with their profile dir or credential present. Views read this many
    /// times per render, so it is kept rather than computed with a stat per account; it is redone when the config
    /// changes and on every tick, which picks up a profile folder that appears or goes away.
    private(set) var accounts: [AccountConfig] = []

    private func refreshAccounts() {
        let visible = config.accounts.filter { $0.enabled && (previewMode || isAvailable($0)) }
        if visible != accounts {
            accounts = visible
            updateConnectivity()
        }
    }

    func status(for account: AccountConfig) -> AccountStatus {
        statuses[account.id] ?? AccountStatus()
    }

    /// Nothing leaves the model: no save, fetch, scan, state file or permission request.
    private var isInert: Bool { previewMode || readOnly }

    /// The newest successful check among the accounts that report windows, else among every account shown. A saved
    /// copy counts with its own date, which is the honest age of what is on screen.
    var lastUpdated: Date? {
        func newest(_ accounts: [AccountConfig]) -> Date? { accounts.compactMap { statuses[$0.id]?.snapshot?.fetchedAt }.max() }
        return newest(accounts.filter(\.provider.reportsWindows)) ?? newest(accounts)
    }

    /// The soonest an automatic check of an account that needs the network can run.
    var nextNetworkCheck: Date? {
        scheduler.nextCheck(accounts.filter(\.provider.checkUsesNetwork).map(\.id))
    }

    var menuBarState: MenuBarState {
        MenuBarState.make(
            accounts: accounts.filter(\.showInMenuBar), statuses: statuses, config: config, now: now,
            connectivity: connectivity, settingsProblem: settingsProblem
        )
    }

    // MARK: Lifecycle

    func start() {
        signal(SIGPIPE, SIG_IGN)
        loadState()

        ticker = Timer.scheduledTimer(withTimeInterval: RefreshScheduler.tickInterval, repeats: true) { [weak self] _ in
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
        network.start { [weak self] path in self?.networkPathChanged(path) }
        Task { await launchRefresh() }
        scanHistory()
    }

    /// The launch refresh waits for the monitor's first report, or `firstPathWait` without one, so a launch while
    /// offline spawns nothing that needs the network.
    @discardableResult
    func launchRefresh(firstPathWait: Duration = .seconds(1)) async -> Task<Void, Never>? {
        if networkWatch.path == nil {
            await withCheckedContinuation { continuation in
                firstPathWaiters.append(continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: firstPathWait)
                    self?.resumeFirstPathWaiters()
                }
            }
        }
        return refresh(force: true)
    }

    private func resumeFirstPathWaiters() {
        let waiters = firstPathWaiters
        firstPathWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Network

    /// Each report from the path monitor. Tests call it directly, so no test touches the Mac's network.
    @discardableResult
    func networkPathChanged(_ path: NetworkPath) -> Task<Void, Never>? {
        let event = networkWatch.report(path, at: clock())
        resumeFirstPathWaiters()
        return networkStateChanged(event)
    }

    /// Runs when `NetworkWatch` said a settle was due. Tests move their clock and call it themselves.
    @discardableResult
    func settleNetwork() -> Task<Void, Never>? {
        networkStateChanged(networkWatch.settle(at: clock()))
    }

    private func networkStateChanged(_ event: NetworkWatch.Event?) -> Task<Void, Never>? {
        scheduleSettle()
        updateConnectivity()
        // Between sleep and the delayed wake refresh, that refresh does the work.
        guard let event, !sleeping else { return nil }
        switch event {
        case .wentOffline:
            return nil
        case .blipEnded:
            return refresh(force: false)
        case .cameBackOnline:
            // Accounts that failed in the seconds before offline was declared were pushed a full interval out, so the
            // first return checks every account. A network that drops and returns every few seconds must not respawn
            // every CLI each time.
            let now = clock()
            if let last = lastBackOnlineRefresh, now.timeIntervalSince(last) < RefreshScheduler.popoverRefreshAge {
                return refresh(force: false)
            }
            lastBackOnlineRefresh = now
            return refresh(force: true)
        }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        guard let due = networkWatch.nextSettle else { return }
        let delay = max(0, due.timeIntervalSince(clock()))
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.settleNetwork()
        }
    }

    /// Previews set `connectivity` themselves.
    private func updateConnectivity() {
        guard !isInert else { return }
        let current = Connectivity.make(watch: networkWatch, accounts: accounts, statuses: statuses, isLatched: probeLatch.isLatched)
        if current != connectivity { connectivity = current }
    }

    /// Everything `start` reads from disk, without timers or observers. The Headroom move comes first, so the config and
    /// the database open under their new names.
    func loadState() {
        if let banner = moveLegacyData() {
            waitingForLegacyMove = true
            configLoadFailed = true
            setConfigProblem(banner, file: nil)
            return
        }
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

    /// What `loadState` shows, for `--render-windows --real-data`: config.json without a first run or the Headroom move,
    /// history from `store` (a copy the caller made), and the probe latch. The model is read-only from here on.
    func loadReadOnly(store: any UsageStore) {
        readOnly = true
        loadConfig()
        self.store = store
        priceTable = PriceTable.load(bundled: ProviderLogo.resourceURL("pricing.json"), override: paths.pricingOverrideFile)
        seedFromStore()
        loadProbeLatch()
    }

    func popoverWillOpen() {
        now = clock()
        popoverNow = now
        guard RefreshScheduler.shouldRefreshOnPopoverOpen(lastRefreshAt: lastRefreshAt, now: now) else { return }
        refresh(force: true)
    }

    @discardableResult
    func tick() -> Task<Void, Never>? {
        now = clock()
        if isPopoverShown { popoverNow = now }
        let day = Calendar.current.startOfDay(for: now)
        if day != historyDay {
            historyDay = day
            historyRevision += 1
        }
        guard !sleeping else { return nil }
        refreshAccounts()
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

    /// nil once nothing of Headroom's is left to move, else the banner that says why it stayed.
    private func moveLegacyData() -> String? {
        let log = Logger(subsystem: AppPaths.bundleIdentifier, category: "legacy-move")
        let running = legacyAppIsRunning()
        for event in LegacyMigration.run(paths: paths, legacyAppIsRunning: running) {
            if case .failed(let reason) = event {
                log.error("Headroom data not moved: \(reason, privacy: .public)")
            } else {
                log.notice("Headroom data: \(String(describing: event), privacy: .public)")
            }
        }
        guard LegacyMigration.hasDataToMove(paths: paths) else { return nil }
        return running
            ? "Headroom is still running, so its settings and history were not moved. Quit Headroom, then reopen Tokenjar."
            : "Headroom's settings and history could not be moved, so neither is loaded. Tokenjar tries again when it next opens."
    }

    // MARK: Config

    /// Only `start` passes `firstRunAllowed`: discovery then writes a new config.json, and only when nothing at all,
    /// not even a dangling stow link, is at its path. A reload never writes, so a config.json missing for a moment
    /// (a branch switch in the dotfiles repo) keeps the current settings instead of replacing the user's.
    func loadConfig(firstRunAllowed: Bool = false) {
        guard !waitingForLegacyMove else { return }
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
                do { try configStore.write(fresh) } catch { setConfigProblem("Could not create config.json.") }
            } else {
                configLoadFailed = true
                setConfigProblem("config.json is missing or its link is broken. Keeping the current settings and saving nothing until it is back.")
            }
        } catch {
            configLoadFailed = true
            setConfigProblem(loadFailureMessage(error), file: Self.fileAtFault(error))
        }
    }

    /// What the app shows after a load of `file` fails, for window renders: nothing is read, and edits stop.
    /// `nothingLoaded` is the launch failure, with no settings from before to keep.
    func showFailedLoad(of file: String, nothingLoaded: Bool) {
        hasLoadedConfig = !nothingLoaded
        configLoadFailed = true
        setConfigProblem(loadFailureMessage(ConfigError.invalidJSON(file: file, detail: "render")), file: file)
    }

    private func setConfigProblem(_ message: String?, file: String? = "config.json") {
        configProblem = message
        configProblemFile = message == nil ? nil : file
    }

    private func configLoaded() {
        configLoadFailed = false
        hasLoadedConfig = true
        setConfigProblem(nil)
    }

    /// An error that names no file is shown against config.json, whose folder also holds config.local.json.
    private static func fileAtFault(_ error: Error) -> String {
        if case ConfigError.invalidJSON(let name, _) = error { return name }
        return "config.json"
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
        guard !isInert, currentConfigStamp() != configStamp else { return }
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
    /// While the last load failed, the edit is neither applied nor saved, and an edit whose save fails is undone; the
    /// banner says why.
    func updateConfig(_ edit: (inout AppConfig) -> Void) {
        // An outside change since the last tick is the base of this edit, or saving would revert it.
        reloadConfigIfChanged()
        guard isInert || !configLoadFailed else { return }
        let old = config
        var new = config
        edit(&new)
        guard new != old else { return }
        config = new
        guard !isInert else { return }
        do {
            baseConfig = try ConfigStore(paths: paths).save(old: old, new: new, base: baseConfig)
            setConfigProblem(nil)
        } catch {
            config = old
            setConfigProblem("Could not save config.json.")
        }
        configStamp = currentConfigStamp()
        refreshEditedAccounts(from: old.accounts)
        // Quiet grant only: the Alerts pane's "Allow banners" is the one place the system prompt appears.
        if config.alerts.enabled, !old.alerts.enabled { requestNotificationPermission(prominent: false) }
    }

    private func refreshEditedAccounts(from old: [AccountConfig]) {
        guard config.accounts != old else { return }
        scheduler.invalidate(config.accounts.filter { !old.contains($0) }.map(\.id))
        refresh(force: false)
    }

    // MARK: Refresh

    /// `force` skips the refresh interval (popover open, wake, the header button) but not a rate-limit backoff.
    /// `userInitiated` is what the user asked for, which macOS's path status never holds back.
    @discardableResult
    func refresh(force: Bool, userInitiated: Bool = false) -> Task<Void, Never>? {
        // Read once: a later reading for the start would push every next check back by the time this one took to begin.
        let current = clock()
        // Removed before `due`, so a held account is never begun, keeps its next due time, and stays due.
        let candidates = !userInitiated && networkWatch.holdsChecks ? accounts.filter { !$0.provider.checkUsesNetwork } : accounts
        let due = Set(scheduler.due(candidates.map(\.id), now: current, force: force))
        return fetch(accounts.filter { due.contains($0.id) }, startedAt: current)
    }

    /// An explicit per-account check, such as Settings > Test: it overrides the interval and a rate-limit backoff. It is
    /// also the only check that asks the Keychain again for a pasted key it found missing or was refused.
    @discardableResult
    func refresh(accountID: String) -> Task<Void, Never>? {
        let targets = accounts.filter { $0.id == accountID && !scheduler.inFlight.contains($0.id) }
        for case .keychain(let name)? in targets.map(\.credential) { secrets.allowRead(account: name) }
        return fetch(targets, startedAt: clock())
    }

    /// The one way to probe an account again after its probe spent tokens or quota: one run, latched again if it
    /// repeats.
    @discardableResult
    func retryProbe(accountID: String) -> Task<Void, Never>? {
        if probeLatch.release(accountID) { saveProbeLatch() }
        return refresh(accountID: accountID)
    }

    private func fetch(_ targets: [AccountConfig], startedAt: Date) -> Task<Void, Never>? {
        guard !isInert else { return nil }
        let targets = withoutLatchedProbes(targets)
        guard !targets.isEmpty else { return nil }
        scheduler.begin(targets.map(\.id), at: startedAt)
        for account in targets {
            statuses[account.id, default: AccountStatus()].isRefreshing = true
        }
        isRefreshing = true
        let startedUnusable = networkWatch.path == .unusable
        let context = FetchContext(secrets: secrets, cli: cliLocator(for: config), paths: paths)
        let jobs = targets.map { ($0, fetcher($0.provider)) }
        return Task {
            var dropped = false, stored = false
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
                    switch apply(result, to: account) {
                    case .dropped: dropped = true
                    case .applied(let sampled): stored = stored || sampled
                    }
                    if startedUnusable, account.provider.checkUsesNetwork, case .success(let snapshot) = result, snapshot.liveCheckFailure == nil {
                        // macOS called the path unusable, yet a provider answered: a VPN or tunnel it misreads. Trusting
                        // the report would stop every automatic check for good.
                        networkWatch.trustAnswers()
                        scheduleSettle()
                    }
                    updateConnectivity()
                    isRefreshing = !scheduler.inFlight.isEmpty
                }
            }
            lastRefreshAt = clock()
            now = clock()
            if isPopoverShown { popoverNow = now }
            if stored { historyRevision += 1 }
            if dropped { refresh(force: false) }
        }
    }

    private enum Applied {
        /// The account was edited, disabled or removed while its fetch ran. The result describes the old settings, so
        /// it is not shown, stored or alerted on, and the account is due again at once.
        case dropped
        /// `sampled` is true when the store kept a new window sample.
        case applied(sampled: Bool)
    }

    private func apply(_ result: Result<UsageSnapshot, FetchError>, to account: AccountConfig) -> Applied {
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
            return .dropped
        }

        var status = statuses[account.id] ?? AccountStatus()
        status.isRefreshing = false
        status.lastAttempt = current
        var sampled = false
        switch result {
        case .success(let snapshot):
            status.snapshot = snapshot
            status.error = nil
            sampled = (try? store?.record(snapshot)) ?? false
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

        let previousAlertState = alertState
        let outcome = AlertEngine.evaluate(account: live ?? account, result: result, config: config, state: &alertState, now: current)
        notifications?.handle(outcome)
        if alertState != previousAlertState { saveAlertState() }
        return .applied(sampled: sampled)
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
        guard !scanning, !isInert, let store else { return }
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
        guard !isInert, let data = try? JSONEncoder().encode(alertState) else { return }
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
        guard !isInert, let data = try? JSONEncoder().encode(probeLatch) else { return }
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
        guard let notifications, !isInert else { return }
        Task {
            notificationPermission = await notifications.requestAuthorization(prominent: prominent)
        }
    }

    /// Reads the current grant without asking, so Settings can show whether alerts arrive as banners or quietly.
    func refreshNotificationPermission() {
        guard let notifications, !isInert else { return }
        Task {
            notificationPermission = await notifications.permission()
        }
    }

    // MARK: Actions

    func openProviderDashboard(_ account: AccountConfig) {
        NSWorkspace.shared.open(account.resolvedDashboardURL)
    }

    /// Selects `file` (config.json or config.local.json) in the Finder through its link, or its folder when it is gone.
    func revealConfigFile(_ file: String) {
        let url = (file == "config.local.json" ? paths.localConfigFile : paths.configFile).resolvingSymlinksInPath()
        let exists = FileManager.default.fileExists(atPath: url.path)
        NSWorkspace.shared.activateFileViewerSelecting([exists ? url : url.deletingLastPathComponent()])
    }

    func openStatusPage(_ account: AccountConfig) {
        if let url = account.provider.statusPageURL { NSWorkspace.shared.open(url) }
    }

    /// Settings' Save Key: stores the key, points the account at it and checks it. An account that already used a pasted
    /// key is not edited, so without the check its card would keep the last failure until the next interval.
    func savePastedKey(_ key: String, accountID: String) throws {
        try secrets.write(key, account: accountID)
        updateAccount(accountID) { $0.credential = .keychain(account: accountID) }
        refresh(accountID: accountID)
    }

    func showDashboard(accountID: String? = nil) { presenter.showDashboard(accountID) }
    func showSettings(accountID: String? = nil) { presenter.showSettings(accountID) }
    func closePopover() { presenter.closePopover() }

    func quit() { NSApp.terminate(nil) }
}
