import Foundation
import TokenjarCore

/// Debounces macOS's path reports into what the scheduler holds and what the UI shows. Pure, so the timing rules are
/// tested with dates in and decisions out, without touching the Mac's network.
struct NetworkWatch {
    enum Event: Equatable {
        case wentOffline
        case cameBackOnline
        /// The path came back before offline was declared.
        case blipEnded
    }

    /// Wake and launch at login often report an unusable path for a few seconds while Wi-Fi associates, and roaming
    /// drops it briefly; neither should flash the slash. Chosen, not measured.
    static let offlineSettle: TimeInterval = 10
    /// Lets DNS and a captive portal settle before every account is checked, and keeps a path that flickers usable
    /// for a second from clearing the slash. Chosen, not measured.
    static let onlineSettle: TimeInterval = 3

    /// nil until the first report.
    private(set) var path: NetworkPath?
    /// What the UI shows: set once the path has been unusable for `offlineSettle` without a break, cleared once it has
    /// been usable for `onlineSettle`.
    private(set) var isOffline = false
    /// A check that ran while held got a live answer, so the path macOS reports is wrong (a VPN or tunnel it calls
    /// unusable). Holds nothing until the next report.
    private(set) var distrusted = false
    /// Offline was declared and `cameBackOnline` has not followed. A lifted hold clears the slash but not this: the
    /// outage still pushed accounts a full interval out, and the next usable path checks them.
    private(set) var returnPending = false
    /// When the current unbroken run of `path` began.
    private var since: Date?

    /// Read by the scheduler from the first unusable report, with no settle: skipping a check costs nothing, and the
    /// skipped account stays due.
    var holdsChecks: Bool { path == .unusable && !distrusted }

    /// Results from before the path last became usable failed on a network that is gone, so they say nothing about
    /// whether providers answer now. nil counts every result.
    var answersSince: Date? { path == .usable ? since : nil }

    /// When `settle(at:)` next has something to decide; nil when nothing is pending.
    var nextSettle: Date? {
        guard let since else { return nil }
        switch path {
        case .unusable where !isOffline && !distrusted: return since.addingTimeInterval(Self.offlineSettle)
        case .usable where returnPending: return since.addingTimeInterval(Self.onlineSettle)
        default: return nil
        }
    }

    mutating func report(_ new: NetworkPath, at now: Date) -> Event? {
        let previous = path
        // A report after a lifted hold starts a fresh run, so a path still called unusable waits the full settle again.
        if new != previous || distrusted {
            path = new
            since = now
            distrusted = false
            if new == .usable, previous == .unusable, !returnPending { return .blipEnded }
        }
        return settle(at: now)
    }

    mutating func settle(at now: Date) -> Event? {
        guard let due = nextSettle, now >= due else { return nil }
        let wentOffline = path == .unusable
        isOffline = wentOffline
        returnPending = wentOffline
        return wentOffline ? .wentOffline : .cameBackOnline
    }

    /// Only while the path reads unusable: once it is usable again an answer proves nothing the path does not.
    mutating func trustAnswers() {
        guard path == .unusable else { return }
        distrusted = true
        isOffline = false
    }

    /// At wake: time asleep is not time awake with or without a network, so a pending settle starts over.
    mutating func restart(at now: Date) {
        if since != nil { since = now }
    }
}

/// Whether Tokenjar can refresh at all right now: the Mac-wide causes the menu bar's slash and the popover header show.
enum Connectivity: Equatable {
    case online, offline, noAnswer

    /// `accounts` are the ones shown on this Mac, and `previous` is what is shown now. No new host is contacted to tell
    /// the causes apart: they are inferred from the path and from the latest results alone.
    static func make(
        watch: NetworkWatch, accounts: [AccountConfig], statuses: [String: AccountStatus], isLatched: (String) -> Bool, previous: Connectivity
    ) -> Connectivity {
        let networked = accounts.filter { $0.enabled && $0.provider.checkUsesNetwork && !isLatched($0.id) }
        // Nothing such a setup shows depends on the network, so it never shows offline.
        guard !networked.isEmpty else { return .online }
        if watch.isOffline { return .offline }
        // A drop too short to call offline decides nothing, so a flapping path neither sets nor clears the slash.
        guard !watch.holdsChecks else { return previous }
        let checked = networked.compactMap { account -> (provider: ProviderID, status: AccountStatus)? in
            guard let status = statuses[account.id], let attempt = status.lastAttempt else { return nil }
            if let since = watch.answersSince, attempt < since { return nil }
            return (account.provider, status)
        }
        if checked.contains(where: { $0.status.providerAnswered }) { return .online }
        // One provider failing alone is that provider's problem, not the connection's.
        let unreachable = Set(checked.filter { $0.status.connectionFailure != nil }.map(\.provider))
        return unreachable.count >= 2 ? .noAnswer : .online
    }
}

private extension AccountStatus {
    /// A rate limit is the provider's own answer too, so the connection to it works.
    var providerAnswered: Bool {
        if case .rateLimited? = error { return true }
        return hasLiveAnswer
    }
}
