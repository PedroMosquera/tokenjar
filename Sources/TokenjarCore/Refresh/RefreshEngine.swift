import Foundation

/// The refresh loop for a front end other than the Mac app, such as the Windows tray. Each enabled account on this
/// machine is fetched when `RefreshScheduler` says it is due, answers are stored, the probe latch is kept and saved where
/// the Mac app keeps it (hard rule 5), and history is scanned every few minutes. The Mac app's AppModel runs the same
/// rules with its UI state on top. Not here yet: alerts, monthly budgets and holding checks while offline.
public actor RefreshEngine {
    /// The last check of one account. A snapshot that check stored is in the store, not here.
    public struct Check: Sendable, Equatable {
        public var at: Date
        /// nil when the check answered.
        public var error: FetchError?
    }

    public private(set) var config = AppConfig()
    /// Why config.json could not be read or written; nil while it is fine. The last settings that loaded stay in use.
    public private(set) var configProblem: String?
    public private(set) var checks: [String: Check] = [:]

    private let paths: AppPaths
    private let store: any UsageStore
    private let process: any ProcessRunning
    private let secrets: any SecretStore
    private let fetcher: @Sendable (ProviderID) -> any UsageFetcher
    private let scanner: @Sendable (ProviderID) -> (any HistoryScanner)?
    private let clock: @Sendable () -> Date
    private var scheduler = RefreshScheduler()
    private var latch = ProbeLatch()
    private var lastScanAt: Date?

    /// `fetcher`, `scanner` and `clock` are seams for tests.
    public init(
        paths: AppPaths, store: any UsageStore, process: any ProcessRunning = FoundationProcessRunner(),
        secrets: any SecretStore = PlatformSecretStore(),
        fetcher: @escaping @Sendable (ProviderID) -> any UsageFetcher = { FetcherRegistry.fetcher(for: $0) },
        scanner: @escaping @Sendable (ProviderID) -> (any HistoryScanner)? = { FetcherRegistry.scanner(for: $0) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.store = store
        self.process = process
        self.secrets = secrets
        self.fetcher = fetcher
        self.scanner = scanner
        self.clock = clock
        if let data = try? Data(contentsOf: paths.supportDirectory.appending(path: ProbeLatch.fileName)),
           let saved = try? JSONDecoder().decode(ProbeLatch.self, from: data) {
            latch = saved
        }
    }

    /// The accounts this machine checks: enabled ones whose profile folder or credential is here, link-only ones aside.
    public var accounts: [AccountConfig] {
        config.accounts.filter { $0.enabled && !$0.provider.isLinkOnly && AccountDiscovery.isAvailable($0, paths: paths) }
    }

    /// Whether `accountID` is held back because its probe started a model turn. Only `retry(accountID:)` lifts that.
    public func isLatched(_ accountID: String) -> Bool { latch.isLatched(accountID) }

    /// What a tray shows now for the accounts this machine checks: their stored snapshots, last checks and latch.
    public func summary() -> TraySummary {
        var checked = config
        checked.accounts = accounts
        let snapshots = (try? store.latestSnapshots()) ?? []
        let latched = Dictionary(uniqueKeysWithValues: latch.accountIDs.compactMap { id in latch.cli(of: id).map { (id, $0) } })
        return TraySummary.make(
            report: StatusReport.make(config: checked, snapshots: snapshots, now: clock()), config: checked, checks: checks,
            latched: latched, configProblem: configProblem, now: clock()
        )
    }

    /// Reads config.json and config.local.json. The first time, when nothing at all is at config.json's path (not even
    /// a dangling link), the accounts found on this machine are written there. A failed read keeps the last settings.
    public func loadConfig() {
        let configStore = ConfigStore(paths: paths)
        do {
            if let loaded = try configStore.load() {
                config = loaded.merged
                configProblem = nil
            } else if (try? FileManager.default.attributesOfItem(atPath: paths.configFile.path)) == nil {
                var fresh = AppConfig()
                fresh.accounts = AccountDiscovery.discover(paths: paths, cli: locator(for: fresh))
                config = fresh
                do {
                    try configStore.write(fresh)
                    configProblem = nil
                } catch {
                    configProblem = "Could not create config.json."
                }
            } else {
                configProblem = "config.json is missing or its link is broken."
            }
        } catch let error as ConfigError {
            configProblem = error.userMessage ?? "Could not read config.json."
        } catch {
            configProblem = "Could not read config.json."
        }
    }

    /// Reloads the config, checks each account that is due (every one when `force`, though never one backing off after
    /// a rate limit or already being checked), then scans history when it is due. Returns once those are done.
    public func tick(force: Bool = false) async {
        loadConfig()
        let now = clock()
        let accounts = self.accounts
        let due = Set(scheduler.due(accounts.map(\.id), now: now, force: force))
        await check(withoutLatchedProbes(accounts.filter { due.contains($0.id) }), startedAt: now)
        if RefreshScheduler.shouldScan(lastScanAt: lastScanAt, now: clock()) { await scanHistory() }
    }

    /// One more probe of an account the latch holds back. It latches again if it starts a model turn again.
    public func retry(accountID: String) async {
        if latch.release(accountID) { saveLatch() }
        loadConfig()
        await check(accounts.filter { $0.id == accountID && !scheduler.inFlight.contains($0.id) }, startedAt: clock())
    }

    /// What `Tokenjar --status` prints, from the snapshots stored so far.
    public func report() -> StatusReport {
        StatusReport.make(config: config, snapshots: (try? store.latestSnapshots()) ?? [], now: clock())
    }

    private func check(_ targets: [AccountConfig], startedAt: Date) async {
        guard !targets.isEmpty else { return }
        scheduler.begin(targets.map(\.id), at: startedAt)
        let context = FetchContext(process: process, secrets: secrets, cli: locator(for: config), paths: paths, now: clock)
        let jobs = targets.map { ($0, fetcher($0.provider)) }
        await withTaskGroup(of: (AccountConfig, Result<UsageSnapshot, FetchError>).self) { group in
            for (account, fetcher) in jobs {
                group.addTask {
                    do {
                        return (account, .success(try await fetcher.fetch(account, context: context)))
                    } catch let error as FetchError {
                        return (account, .failure(error))
                    } catch {
                        return (account, .failure(.network(String(describing: type(of: error)))))
                    }
                }
            }
            for await (account, result) in group { apply(result, to: account) }
        }
    }

    /// AppModel.apply without the UI: an answer for settings edited meanwhile is dropped and the account is due again,
    /// except a model turn, which has spent tokens whatever changed and always latches.
    private func apply(_ result: Result<UsageSnapshot, FetchError>, to account: AccountConfig) {
        let now = clock()
        var modelTurn: ProbeLatch.CLI?, rateLimited = false
        if case .failure(let error) = result {
            modelTurn = ProbeLatch.CLI(modelTurn: error)
            if case .rateLimited = error { rateLimited = true }
        }
        guard config.accounts.first(where: { $0.id == account.id }) == account || modelTurn != nil else {
            scheduler.finish(account.id, at: now, delay: nil, rateLimited: false)
            return
        }
        switch result {
        case .success(let snapshot):
            _ = try? store.record(snapshot)
            checks[account.id] = Check(at: now, error: nil)
        case .failure(let error):
            checks[account.id] = Check(at: now, error: error)
        }
        let delay = RefreshScheduler.retryDelay(
            accountMinutes: account.refreshMinutes, globalMinutes: config.refreshMinutes, lowPower: false, result: result
        )
        scheduler.finish(account.id, at: now, delay: delay, rateLimited: rateLimited)
        if let modelTurn {
            latch.latch(account.id, cli: modelTurn, binary: ProbeLatch.fingerprint(ofBinaryAt: locator(for: config).locate(modelTurn.rawValue)))
            saveLatch()
        }
    }

    /// Latched accounts stay out, unless the binary of the CLI that ran the turn has changed since.
    private func withoutLatchedProbes(_ targets: [AccountConfig]) -> [AccountConfig] {
        guard !latch.isEmpty else { return targets }
        let locator = locator(for: config)
        if latch.releaseAll(unlessBinary: { ProbeLatch.fingerprint(ofBinaryAt: locator.locate($0.rawValue)) }) { saveLatch() }
        return targets.filter { !latch.isLatched($0.id) }
    }

    private func scanHistory() async {
        let jobs = accounts.compactMap { account in scanner(account.provider).map { (account, $0) } }
        let store = self.store, paths = self.paths
        // Detached so a first scan of a large history does not hold the actor, and with it the tray's reads.
        _ = await Task.detached(priority: .utility) { HistoryScanJob.run(jobs, store: store, paths: paths) }.value
        lastScanAt = clock()
    }

    private func saveLatch() {
        guard let data = try? JSONEncoder().encode(latch) else { return }
        let file = paths.supportDirectory.appending(path: ProbeLatch.fileName)
        try? AppPaths.createOwnerOnlyDirectory(file.deletingLastPathComponent())
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func locator(for config: AppConfig) -> CLILocator {
        CLILocator(home: paths.home, overrides: config.cliPaths)
    }
}
