import Foundation
import os
import Testing
@testable import Tokenjar
import TokenjarCore

// Status checks go through an injected fetcher and an in-memory preferences store: no test reaches a status host or
// this Mac's preferences.

/// Records each status page asked and answers with what the test set, a calm answer unless told otherwise.
private nonisolated final class HealthAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [ProviderID] = []
    private var outcomes: [ProviderID: Result<ProviderHealthAnswer, FetchError>] = [:]
    private var heldBy: Gate?
    let answeredAt: @Sendable () -> Date

    init(answeredAt: @escaping @Sendable () -> Date) { self.answeredAt = answeredAt }

    var total: Int { lock.withLock { asked.count } }
    func counts(_ providers: ProviderID...) -> [Int] { lock.withLock { providers.map { p in asked.filter { $0 == p }.count } } }
    func answer(_ provider: ProviderID, _ outcome: Result<ProviderHealthAnswer, FetchError>) { lock.withLock { outcomes[provider] = outcome } }
    func hold(with gate: Gate?) { lock.withLock { heldBy = gate } }

    func fetch(_ provider: ProviderID) async throws -> ProviderHealthAnswer {
        let gate = lock.withLock { () -> Gate? in
            asked.append(provider)
            return heldBy
        }
        if let gate { await gate.wait() }
        let outcome = lock.withLock { outcomes[provider] }
        return try (outcome ?? .success(ProviderHealthAnswer(items: [], answeredAt: answeredAt()))).get()
    }
}

/// The gate the next account checks wait on, if any.
private nonisolated final class AccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Gate?
    var gate: Gate? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// Answers every request with one body, as a status host would.
private nonisolated struct BodyTransport: HTTPTransport {
    var body: Data
    func send(_ request: URLRequest) async throws -> HTTPResponse { HTTPResponse(status: 200, body: body) }
}

@MainActor
struct AppModelHealthTests {
    private let claude = AccountConfig(id: "claude", provider: .claude, label: "Personal")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "Plus")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub")
    private let outage = ProviderHealthItem(level: .majorOutage, names: ["Copilot"], title: "Incident with GitHub.com")

    private struct Rig {
        let home: ModelHome
        let model: AppModel
        let asks: HealthAsks
        let clock: TestClock
        let log: FetchLog
        let defaults: MemoryDefaults
        let accountGate: AccountGate
    }

    /// `switchOn` nil leaves the preference unset, as on a Mac where nobody touched it. `available` says which accounts
    /// have their profile or credential on this Mac.
    private func rig(
        _ accounts: [AccountConfig], switchOn: Bool? = true, defaults: MemoryDefaults = MemoryDefaults(),
        available: @escaping (AccountConfig) -> Bool = { _ in true },
        accountResult: @escaping @Sendable (AccountConfig) -> Result<UsageSnapshot, FetchError> = { .success(usageSnapshot($0)) },
        healthFetcher: (@Sendable (ProviderID) async throws -> ProviderHealthAnswer)? = nil,
        prepare: (ModelHome, [AccountConfig]) throws -> Void = { try $0.writeConfig(AppConfig(accounts: $1)) }
    ) throws -> Rig {
        let home = try ModelHome()
        try prepare(home, accounts)
        if let switchOn { defaults.set(switchOn, forKey: ProviderHealthSetting.key) }
        let log = FetchLog(), clock = TestClock(), accountGate = AccountGate()
        let start = clock.now
        let asks = HealthAsks(answeredAt: { start })
        let fetchHealth: @Sendable (ProviderID) async throws -> ProviderHealthAnswer = healthFetcher ?? { try await asks.fetch($0) }
        let model = AppModel(
            paths: home.paths, fetcher: { _ in FakeFetcher(log: log, gate: accountGate.gate, result: accountResult) }, clock: { clock.now },
            network: FakeNetworkStatus(), healthFetcher: fetchHealth, defaults: defaults
        )
        model.isAvailable = available
        model.loadState()
        return Rig(home: home, model: model, asks: asks, clock: clock, log: log, defaults: defaults, accountGate: accountGate)
    }

    private func open(_ rig: Rig) async {
        rig.model.popoverWillOpen()
        await rig.model.healthCheck?.value
    }

    private func refreshNow(_ rig: Rig) async {
        await PopoverHeader.refreshNow(rig.model)?.value
        await rig.model.healthCheck?.value
    }

    private func goOffline(_ rig: Rig) {
        rig.model.networkPathChanged(.unusable)
        rig.clock.advance(NetworkWatch.offlineSettle)
        rig.model.settleNetwork()
    }

    /// Counted from the last request, answered or not, so a host that keeps failing is not asked on every open.
    @Test func popoverOpenAsksAgainOnlyAfterTwoMinutesEvenAfterAFailure() async throws {
        let rig = try rig([claude, codex, copilot])
        defer { rig.home.remove() }
        rig.asks.answer(.copilot, .failure(.network("HTTP 503")))

        await open(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [1, 1, 1])
        rig.clock.advance(119)
        await open(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [1, 1, 1])
        rig.clock.advance(1)
        await open(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [2, 2, 2])
    }

    /// The status rule keeps its own clock: an account refresh just before an open, as a wake or a tick makes, must not
    /// hold back a status page that is due.
    @Test func anAccountRefreshJustBeforeAnOpenDoesNotHoldBackADueCheck() async throws {
        let rig = try rig([claude])
        defer { rig.home.remove() }
        await open(rig)
        try await waitUntil { rig.model.lastRefreshAt != nil }
        rig.clock.advance(300)
        await rig.model.refresh(force: true)?.value
        rig.clock.advance(10)
        await open(rig)
        #expect(rig.log.count("claude") == 2)
        #expect(rig.asks.counts(.claude) == [2])
    }

    /// The refresh button, Command-R and Refresh Now share this path, and the user asked: no two-minute wait.
    @Test func refreshAsksEveryProviderAtOnce() async throws {
        let rig = try rig([claude, codex, copilot])
        defer { rig.home.remove() }
        await open(rig)
        rig.clock.advance(10)
        await refreshNow(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [2, 2, 2])
    }

    /// Each of these forces an account refresh, as popover open does, yet none of them is the user looking.
    @Test func launchTicksWakeAndAReturnFromOfflineNeverAsk() async throws {
        let rig = try rig([claude, codex, copilot])
        defer { rig.home.remove() }

        await rig.model.launchRefresh(firstPathWait: .milliseconds(20))?.value
        rig.clock.advance(11 * 60)
        await rig.model.tick()?.value
        rig.model.systemWillSleep()
        await rig.model.systemDidWake(networkDelay: .zero)?.value
        goOffline(rig)
        rig.model.networkPathChanged(.usable)
        rig.clock.advance(NetworkWatch.onlineSettle)
        await rig.model.settleNetwork()?.value
        await rig.model.refresh(force: true)?.value

        #expect(rig.log.count("claude") >= 4)
        #expect(rig.asks.total == 0)
        #expect(rig.model.healthCheck == nil)
    }

    /// Every install was promised one request of its own; the switch starts off and nothing turns it on.
    @Test func offAsksNothing() async throws {
        let rig = try rig([claude, codex, copilot], switchOn: nil)
        defer { rig.home.remove() }
        #expect(!rig.model.providerStatusOn)
        await open(rig)
        await refreshNow(rig)
        #expect(rig.asks.total == 0)
    }

    /// Turning the switch on is not a look at the popover: the next open or refresh asks.
    @Test func turningTheSwitchOnAsksNothing() async throws {
        let rig = try rig([claude, codex, copilot], switchOn: nil)
        defer { rig.home.remove() }
        rig.model.setProviderStatus(true)
        await rig.model.healthCheck?.value
        #expect(rig.asks.total == 0)
        #expect(rig.model.healthCheck == nil)
        await open(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [1, 1, 1])
    }

    /// config.json can list accounts this Mac does not use, a disabled one or one whose profile is not here. Neither may
    /// make this Mac contact its provider's status page.
    @Test func disabledAndAbsentAccountsAreNotAskedFor() async throws {
        let disabled = AccountConfig(id: "copilot", provider: .copilot, label: "GitHub", enabled: false)
        let rig = try rig([claude, codex, disabled], available: { $0.id != "codex" })
        defer { rig.home.remove() }
        #expect(rig.model.accounts.map(\.id) == ["claude"])
        await refreshNow(rig)
        #expect(rig.asks.counts(.claude, .codex, .copilot) == [1, 0, 0])
    }

    /// One request per provider at a time: a second refresh, or an open, while a check still runs sends nothing more.
    @Test func aProviderWhoseCheckIsStillRunningIsNotAskedAgain() async throws {
        let rig = try rig([copilot])
        defer { rig.home.remove() }
        let gate = Gate()
        rig.asks.hold(with: gate)
        await PopoverHeader.refreshNow(rig.model)?.value
        try await waitUntil { rig.asks.total == 1 }
        let first = rig.model.healthCheck

        rig.clock.advance(ProviderHealth.askAgainAfter)
        await PopoverHeader.refreshNow(rig.model)?.value
        rig.model.popoverWillOpen()
        await gate.open()
        await first?.value
        await rig.model.healthCheck?.value
        #expect(rig.asks.counts(.copilot) == [1])
        #expect(rig.model.healthInFlight.isEmpty)
    }

    /// One request per provider, however many accounts share it, and none for a provider without a feed.
    @Test func onlyProvidersWithAnAccountAndAFeedAreAskedOnceEach() async throws {
        let work = AccountConfig(id: "claude-work", provider: .claude, label: "Work")
        let go = AccountConfig(id: "go", provider: .opencodeGo, label: "Go")
        let zen = AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen")
        let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")
        let rig = try rig([claude, work, go, zen, devin])
        defer { rig.home.remove() }
        await refreshNow(rig)
        #expect(rig.asks.total == 1)
        #expect(rig.asks.counts(.claude) == [1])
    }

    /// Popover open is held like any automatic check, a refresh is not, and a status answer never lifts the hold: only
    /// an account's own provider answering can.
    @Test func offlineHoldsThePopoverCheckAndAStatusAnswerNeverLiftsIt() async throws {
        let rig = try rig([claude, copilot], accountResult: { _ in .failure(.network("dial tcp")) })
        defer { rig.home.remove() }
        rig.model.networkPathChanged(.usable)
        goOffline(rig)

        await open(rig)
        #expect(rig.asks.total == 0)
        await refreshNow(rig)
        #expect(rig.asks.counts(.claude, .copilot) == [1, 1])
        #expect(rig.model.connectivity == .offline)

        rig.clock.advance(ProviderHealth.askAgainAfter)
        await open(rig)
        #expect(rig.asks.counts(.claude, .copilot) == [1, 1])
    }

    /// Learning nothing new is not news that the problem is over, and a status host saying nothing says nothing about
    /// the accounts, the network or the menu bar.
    @Test func aFailedCheckKeepsTheLastAnswerAndChangesNothingElse() async throws {
        let rig = try rig([claude, copilot])
        defer { rig.home.remove() }
        rig.asks.answer(.copilot, .success(ProviderHealthAnswer(items: [outage], answeredAt: rig.clock.now)))
        await refreshNow(rig)
        let card = AccountCard.healthText(provider: .copilot, health: rig.model.providerHealth, now: rig.clock.now)
        #expect(card?.lead == "Major outage on Copilot: Incident with GitHub.com")
        let statuses = rig.model.statuses, connectivity = rig.model.connectivity, menuBar = rig.model.menuBarState

        rig.asks.answer(.copilot, .failure(.timeout))
        rig.asks.answer(.claude, .failure(.network("URLError -1009")))
        // The account checks wait, so nothing they do afterwards can hide what the status checks did.
        let gate = Gate()
        rig.accountGate.gate = gate
        let accountChecks = PopoverHeader.refreshNow(rig.model)
        await rig.model.healthCheck?.value

        #expect(rig.asks.counts(.copilot) == [2])
        #expect(rig.model.providerHealth[.copilot]?.lastFailure == .timeout)
        #expect(AccountCard.healthText(provider: .copilot, health: rig.model.providerHealth, now: rig.clock.now) == card)
        #expect(rig.model.connectivity == connectivity)
        #expect(rig.model.statuses.mapValues(\.error) == statuses.mapValues(\.error))
        #expect(!rig.model.menuBarState.showsDot)
        #expect(rig.model.menuBarState.isSlashed == menuBar.isSlashed)
        await gate.open()
        await accountChecks?.value
    }

    /// An answer that lands after the switch went off must not bring a row back.
    @Test func turningOffForgetsAnswersAndDropsOneInFlight() async throws {
        let rig = try rig([copilot])
        defer { rig.home.remove() }
        rig.asks.answer(.copilot, .success(ProviderHealthAnswer(items: [outage], answeredAt: rig.clock.now)))
        await refreshNow(rig)
        #expect(rig.model.providerHealth[.copilot]?.answer != nil)

        let gate = Gate()
        rig.asks.hold(with: gate)
        rig.clock.advance(10)
        await PopoverHeader.refreshNow(rig.model)?.value
        try await waitUntil { rig.asks.total == 2 }
        #expect(rig.model.healthInFlight == [.copilot])
        rig.model.setProviderStatus(false)
        #expect(rig.model.providerHealth.isEmpty)
        #expect(rig.model.healthInFlight.isEmpty)
        await gate.open()
        await rig.model.healthCheck?.value

        #expect(rig.model.providerHealth.isEmpty)
        #expect(rig.defaults.object(forKey: ProviderHealthSetting.key) as? Bool == false)
    }

    /// Renders and `--real-data` build models that must never reach the network.
    @Test func previewsAndReadOnlyModelsNeverAsk() async throws {
        let asks = HealthAsks(answeredAt: { Date() })
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: ProviderHealthSetting.key)
        let preview = AppModel(paths: .preview, healthFetcher: { try await asks.fetch($0) }, defaults: defaults)
        preview.previewMode = true
        preview.config = AppConfig(accounts: [claude, codex, copilot])
        #expect(preview.providerStatusOn)
        preview.popoverWillOpen()
        #expect(preview.checkProviderHealth(userInitiated: true) == nil)
        await PopoverHeader.refreshNow(preview)?.value

        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig(accounts: [claude, codex, copilot]))
        let readOnly = AppModel(paths: home.paths, healthFetcher: { try await asks.fetch($0) }, defaults: defaults)
        readOnly.isAvailable = { _ in true }
        readOnly.loadReadOnly(store: InMemoryUsageStore())
        #expect(readOnly.checkProviderHealth(userInitiated: true) == nil)
        #expect(asks.total == 0)
    }

    /// config.json can be shared between Macs, so a key there must not make this one contact status hosts.
    @Test func theSwitchIsThisMacsPreferenceAndNeverConfig() async throws {
        let shared = try rig([claude, codex, copilot], switchOn: nil, prepare: { home, accounts in
            try home.writeConfig(AppConfig(accounts: accounts))
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: home.configFile)) as! [String: Any]
            json["providerStatus"] = true
            try JSONSerialization.data(withJSONObject: json).write(to: home.configFile)
        })
        defer { shared.home.remove() }
        #expect(!shared.model.providerStatusOn)
        await refreshNow(shared)
        #expect(shared.asks.total == 0)

        shared.model.setProviderStatus(true)
        #expect(shared.defaults.object(forKey: ProviderHealthSetting.key) as? Bool == true)
        #expect(AppModel(paths: shared.home.paths, defaults: shared.defaults).providerStatusOn)
        #expect(try String(contentsOf: shared.home.configFile, encoding: .utf8).contains("providerStatus"))
        #expect(try shared.home.readConfig() == AppConfig(accounts: [claude, codex, copilot]))
    }

    /// Any store but the app's own preferences would turn the switch off again at every launch. In a test process
    /// `UserDefaults.standard` is the test runner's domain, not Tokenjar's, and nothing here writes to it.
    @Test func theAppKeepsTheSwitchInItsOwnPreferences() {
        #expect(AppDelegate().model.preferences as? UserDefaults === UserDefaults.standard)
    }

    /// The real fetcher, given a body that is not a status summary: Settings is where that shows.
    @Test func anAnswerThatDoesNotDecodeShowsInSettings() async throws {
        let http = HTTPClient(transport: BodyTransport(body: Data("<html></html>".utf8)))
        let rig = try rig([codex], healthFetcher: { try await ProviderHealthFetcher(http: http).fetch($0) })
        defer { rig.home.remove() }
        await refreshNow(rig)
        let lines = ProviderStatusLines.make(accounts: rig.model.accounts, health: rig.model.providerHealth, inFlight: rig.model.healthInFlight, now: rig.clock.now)
        #expect(lines == ["Codex: couldn't read the answer, just now."])
    }
}

@MainActor
struct ProviderStatusLinesTests {
    private let now = Date(timeIntervalSince1970: 1_791_660_000)
    private let accounts = [
        AccountConfig(id: "claude", provider: .claude, label: "Personal"),
        AccountConfig(id: "claude-work", provider: .claude, label: "Work"),
        AccountConfig(id: "zen", provider: .opencodeZen, label: "Zen"),
        AccountConfig(id: "codex", provider: .codex, label: "Plus"),
        AccountConfig(id: "copilot", provider: .copilot, label: "GitHub"),
    ]

    private func checked(_ ago: TimeInterval, _ result: Result<ProviderHealthAnswer, FetchError>) -> ProviderHealth {
        var health = ProviderHealth()
        health.asked(at: now.addingTimeInterval(-ago))
        health.record(result)
        return health
    }

    /// A failed check changes nothing on the cards, so "couldn't check" would otherwise look like "fine".
    @Test func eachProviderWithAnAccountGetsTheOutcomeOfItsLastCheck() {
        let answered = Result<ProviderHealthAnswer, FetchError>.success(ProviderHealthAnswer(items: [], answeredAt: now))
        let health = [ProviderID.claude: checked(120, answered), .codex: checked(3 * 3_600, .failure(.parse("page data has no group")))]
        #expect(ProviderStatusLines.make(accounts: accounts, health: health, inFlight: [], now: now) == [
            "Claude: answered 2m ago.",
            "Codex: couldn't read the answer, 3h ago.",
            "GitHub Copilot: not asked yet.",
        ])
        #expect(ProviderStatusLines.make(accounts: accounts, health: health, inFlight: [.copilot], now: now).last == "GitHub Copilot: checking now.")
    }

    @Test func eachKindOfFailureIsNamed() {
        func line(_ error: FetchError) -> String? {
            ProviderStatusLines.make(accounts: [accounts[4]], health: [.copilot: checked(60, .failure(error))], inFlight: [], now: now).first
        }
        #expect(line(.timeout) == "GitHub Copilot: no answer within 10 s, 1m ago.")
        #expect(line(.network("HTTP 503")) == "GitHub Copilot: the page answered HTTP 503, 1m ago.")
        #expect(line(.network("URLError -1009")) == "GitHub Copilot: couldn't reach www.githubstatus.com, 1m ago.")
    }

    @Test func noProviderWithAFeedSaysNothingIsAsked() {
        #expect(ProviderStatusLines.make(accounts: [accounts[2]], health: [:], inFlight: [], now: now) == [
            "No Claude, Codex or GitHub Copilot account on this Mac, so no status page is asked.",
        ])
    }

    /// The unified log keeps `.notice` lines on disk; a decode failure is Tokenjar's own bug and is an error.
    @Test func aFailedCheckLogsTheHostAndTheKindNeverTheAnswer() {
        let decode = AppModel.healthLogLine(.codex, .parse("page data has no group"))
        #expect(decode.level == .error)
        #expect(decode.message == "status.openai.com: the answer did not decode (page data has no group)")
        let http = AppModel.healthLogLine(.claude, .network("HTTP 503"))
        #expect(http.level == .default)
        #expect(http.message == "status.claude.com: HTTP 503")
        #expect(AppModel.healthLogLine(.copilot, .timeout).message == "www.githubstatus.com: no answer within 10 s")
    }
}
