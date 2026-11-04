import Foundation
import Observation
import TokenjarCore

enum UpdateStatus: Equatable {
    case unknown, checking, upToDate(checkedAt: Date), available(ReleaseInfo), failed(at: Date)
}

/// Asks GitHub whether a newer Tokenjar exists. Nothing is sent until the user turns on Automatic or presses Check
/// now. Automatic checks run at most once a day, and a failed attempt waits that day too.
@MainActor @Observable
final class UpdateChecker {
    static let modeKey = "updateCheck"
    static let lastCheckKey = "updateLastCheck"
    static let latestVersionKey = "updateLatestVersion"
    static let notifiedVersionKey = "updateNotifiedVersion"

    /// Called only for an automatic check that finds a version newer than any already announced.
    @ObservationIgnored var onNewVersion: (_ installed: AppVersion, _ latest: AppVersion) -> Void = { _, _ in }

    private(set) var status: UpdateStatus

    var mode: UpdateCheckMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// When the latest attempt started, successful or not.
    var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    /// A build without a readable version cannot compare anything, so it never asks.
    var canCheck: Bool { installed != nil }

    @ObservationIgnored private let defaults: any DefaultsStoring
    @ObservationIgnored private let installed: AppVersion?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let fetch: @Sendable () async throws -> ReleaseInfo
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    init(
        defaults: any DefaultsStoring, installed: AppVersion?, clock: @escaping () -> Date = { Date() },
        fetch: @escaping @Sendable () async throws -> ReleaseInfo = { try await UpdateFetcher().fetch() }
    ) {
        self.defaults = defaults
        self.installed = installed
        self.clock = clock
        self.fetch = fetch
        mode = (defaults.object(forKey: Self.modeKey) as? String).flatMap(UpdateCheckMode.init(rawValue:)) ?? .manual
        if let installed, let latest = Self.version(defaults, Self.latestVersionKey), latest > installed,
           let release = UpdateFetcher.releaseInfo(for: latest) {
            status = .available(release)
        } else {
            status = .unknown
        }
    }

    @discardableResult
    func checkIfDue(holdsChecks: Bool) -> Task<Void, Never>? {
        guard canCheck, !holdsChecks,
              UpdateSchedule.isDue(mode: mode, lastCheckAt: lastCheck, now: clock())
        else { return nil }
        return start(userInitiated: false)
    }

    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        guard canCheck else { return nil }
        return start(userInitiated: true)
    }

    private func start(userInitiated: Bool) -> Task<Void, Never>? {
        guard inFlight == nil, let installed else { return nil }
        let startedAt = clock()
        defaults.set(startedAt, forKey: Self.lastCheckKey)
        status = .checking
        let fetch = fetch
        let task = Task {
            do {
                apply(try await fetch(), installed: installed, startedAt: startedAt, userInitiated: userInitiated)
            } catch {
                fail(installed: installed, at: startedAt)
            }
            inFlight = nil
        }
        inFlight = task
        return task
    }

    /// A failed check says nothing about a release already seen, so a known newer version stays on offer.
    private func fail(installed: AppVersion, at date: Date) {
        if let known = Self.version(defaults, Self.latestVersionKey), known > installed,
           let release = UpdateFetcher.releaseInfo(for: known) {
            status = .available(release)
        } else {
            status = .failed(at: date)
        }
    }

    private func apply(_ release: ReleaseInfo, installed: AppVersion, startedAt: Date, userInitiated: Bool) {
        let decision = UpdateSchedule.decide(
            latest: release.version, installed: installed,
            notified: Self.version(defaults, Self.notifiedVersionKey), userInitiated: userInitiated
        )
        defaults.set(release.version.description, forKey: Self.latestVersionKey)
        defaults.set(decision.notifiedVersion?.description, forKey: Self.notifiedVersionKey)
        status = release.version > installed ? .available(release) : .upToDate(checkedAt: startedAt)
        if decision.notify { onNewVersion(installed, release.version) }
    }

    private static func version(_ defaults: any DefaultsStoring, _ key: String) -> AppVersion? {
        (defaults.object(forKey: key) as? String).flatMap(AppVersion.init)
    }
}
