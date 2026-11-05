import Foundation
import Observation
import TokenjarCore

enum UpdateFailure: Equatable {
    case couldNotStart, build, homebrewBehind, install
}

enum UpdateProgress: Equatable {
    case idle
    /// `waitsForIdle` marks a silent install, which swaps only once no Tokenjar window is open.
    case building(AppVersion, waitsForIdle: Bool)
    /// Built by a silent install and waiting for no Tokenjar window to be open, or for Update Now.
    case ready(AppVersion)
    /// The swap has started and quits this app; the next launch reports how it went.
    case installing(AppVersion)
    case failed(AppVersion, UpdateFailure)

    /// What About shows while an update runs, nil otherwise.
    var busyText: String? {
        switch self {
        case .building(let version, waitsForIdle: false):
            "Building \(version). This takes a few minutes, then Tokenjar quits and opens the new version."
        case .building(let version, waitsForIdle: true):
            "Building \(version). Tokenjar installs it once no Tokenjar window is open."
        case .installing(let version): "Installing \(version). Tokenjar quits and opens the new version."
        case .idle, .failed, .ready: nil
        }
    }
}

protocol UpdateRunning: Sendable {
    /// Runs `step` to its end with its output appended to `log`, and returns its exit status.
    func build(_ step: UpdateStep, log: URL) async -> Int32
    /// Starts `step` with its output appended to `log` and returns at once. The process outlives this app, which it
    /// normally quits; `onExit` runs only when the app is still running as it ends.
    func install(_ step: UpdateStep, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws
}

/// Builds the new version without touching the installed app, then starts the swap, which quits this app and opens
/// the new one. A failed build leaves this app running as it is. Update Now swaps as soon as the build is done; a
/// silent install (Install updates automatically) waits for a tick with no Tokenjar window open.
@MainActor @Observable
final class Updater {
    static let swappingToKey = "updateSwappingTo"
    static let autoInstallKey = "updateAutoInstall"
    /// The last version a silent install started on, so each version is tried by itself once.
    static let autoInstallTriedKey = "updateAutoInstallTried"

    private(set) var progress: UpdateProgress = .idle
    /// Nil until checked.
    private(set) var commandLineTools: Bool?

    /// Install updates automatically, kept in this Mac's preferences. A missing value is off, so an upgrade never
    /// turns it on.
    var autoInstall: Bool {
        didSet { defaults.set(autoInstall, forKey: Self.autoInstallKey) }
    }

    /// Called once, on the first launch after a swap that installed this version.
    @ObservationIgnored var onUpdated: (AppVersion) -> Void = { _ in }
    /// Called once per version, when a silent install of it fails.
    @ObservationIgnored var onCouldNotUpdate: (AppVersion) -> Void = { _ in }
    /// Quits this copy when a swap succeeded without quitting it, since install.sh has already opened the new one.
    @ObservationIgnored var quit: () -> Void = {}

    @ObservationIgnored private let defaults: any DefaultsStoring
    @ObservationIgnored private let installed: AppVersion?
    @ObservationIgnored private let appBundle: String
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let temporaryDirectory: String?
    @ObservationIgnored private let fileExists: (String) -> Bool
    @ObservationIgnored private let folderWritable: (String) -> Bool
    @ObservationIgnored private let kegVersion: (_ prefix: String) -> AppVersion?
    @ObservationIgnored private let runner: any UpdateRunning
    @ObservationIgnored private let toolsInstalled: @Sendable () async -> Bool
    /// The swap for the `.ready` build, planned when its build started so it matches what was built.
    @ObservationIgnored private var readyInstall: UpdateStep?

    init(
        defaults: any DefaultsStoring, installed: AppVersion?, appBundle: String, paths: AppPaths, temporaryDirectory: String?,
        fileExists: @escaping (String) -> Bool, folderWritable: @escaping (String) -> Bool,
        kegVersion: @escaping (_ prefix: String) -> AppVersion?, runner: any UpdateRunning,
        toolsInstalled: @escaping @Sendable () async -> Bool
    ) {
        self.defaults = defaults
        self.installed = installed
        self.appBundle = appBundle
        self.paths = paths
        self.temporaryDirectory = temporaryDirectory
        self.fileExists = fileExists
        self.folderWritable = folderWritable
        self.kegVersion = kegVersion
        self.runner = runner
        self.toolsInstalled = toolsInstalled
        autoInstall = defaults.object(forKey: Self.autoInstallKey) as? Bool ?? false
    }

    var blocker: UpdateBlocker? {
        UpdateBlocker.check(appBundle: appBundle, folderWritable: folderWritable, commandLineTools: commandLineTools)
    }

    var isBusy: Bool {
        switch progress {
        case .building, .installing: true
        case .idle, .failed, .ready: false
        }
    }

    var logFile: URL { paths.updateLogFile }

    @discardableResult
    func refreshPrerequisites() -> Task<Void, Never> {
        let toolsInstalled = toolsInstalled
        return Task { commandLineTools = await toolsInstalled() }
    }

    /// Update Now. A build a silent install already finished is swapped in at once, and one still running swaps as
    /// soon as it is done instead of waiting for the windows to close.
    @discardableResult
    func start(_ version: AppVersion) -> Task<Void, Never>? {
        switch progress {
        case .ready(version):
            guard blocker == nil, let step = readyInstall else { return nil }
            swap(version, step, silent: false)
            return nil
        case .building(version, waitsForIdle: true):
            progress = .building(version, waitsForIdle: false)
            return nil
        default:
            return begin(version, waitsForIdle: false)
        }
    }

    /// An automatic check found `latest`. With Install updates automatically on, a version not tried by itself
    /// before starts building; the try is spent as it starts, so an attempt cut short by quitting counts.
    @discardableResult
    func found(_ latest: AppVersion) -> Task<Void, Never>? {
        let tried = defaults.object(forKey: Self.autoInstallTriedKey) as? String
        guard autoInstall, tried != latest.description, canBegin(latest) else { return nil }
        defaults.set(latest.description, forKey: Self.autoInstallTriedKey)
        return begin(latest, waitsForIdle: true, triedBefore: tried)
    }

    /// Called every tick. Swaps in a silent install's build when no Tokenjar window is open and silent installs are
    /// still on; `automatic` is whether update checks are Automatic, which the checkbox sits under.
    @discardableResult
    func installIfIdle(windowOpen: Bool, automatic: Bool) -> Bool {
        guard case .ready(let version) = progress, autoInstall, automatic, !windowOpen, blocker == nil,
              let step = readyInstall
        else { return false }
        swap(version, step, silent: true)
        return true
    }

    /// Reports the swap a previous run started, once: the key is cleared whatever the outcome.
    func finishPendingSwap() {
        let swappingTo = (defaults.object(forKey: Self.swappingToKey) as? String).flatMap(AppVersion.init)
        defaults.set(nil, forKey: Self.swappingToKey)
        switch SwapOutcome.after(swappingTo: swappingTo, installed: installed) {
        case .updated(let version):
            try? FileManager.default.removeItem(at: paths.updateStageDirectory)
            onUpdated(version)
        case .failed(let version):
            progress = .failed(version, .install)
            if defaults.object(forKey: Self.autoInstallTriedKey) as? String == version.description { onCouldNotUpdate(version) }
        case nil:
            break
        }
    }

    private func canBegin(_ version: AppVersion) -> Bool {
        // A notice can be clicked after that version is already installed.
        guard !isBusy, blocker == nil, let installed else { return false }
        return version > installed
    }

    /// `triedBefore` is what `autoInstallTriedKey` held before a silent install spent this version's try.
    private func begin(_ version: AppVersion, waitsForIdle: Bool, triedBefore: String? = nil) -> Task<Void, Never>? {
        guard canBegin(version) else { return nil }
        let method = UpdateCommand.method(fileExists: fileExists)
        let plan = UpdatePlan.make(
            method: method, version: version, appBundle: appBundle, home: paths.home.path,
            stageDirectory: paths.updateStageDirectory.path, temporaryDirectory: temporaryDirectory
        )
        readyInstall = nil
        do {
            try prepare()
        } catch {
            fail(version, .couldNotStart, silent: waitsForIdle)
            return nil
        }
        progress = .building(version, waitsForIdle: waitsForIdle)
        let runner = runner, log = logFile
        return Task {
            let status = await runner.build(plan.build, log: log)
            // Update Now may have been clicked while it built.
            let silent = progress == .building(version, waitsForIdle: true)
            guard status == 0 else { return fail(version, .build, silent: silent) }
            // brew upgrade succeeds without upgrading when its tap has not seen the release yet.
            if case .homebrew(let prefix) = method, !(kegVersion(prefix).map { $0 >= version } ?? false) {
                // The tap trails the release, so the next daily check tries this version again.
                if waitsForIdle { defaults.set(triedBefore, forKey: Self.autoInstallTriedKey) }
                progress = .failed(version, .homebrewBehind)
                return
            }
            guard silent else { return swap(version, plan.install, silent: false) }
            readyInstall = plan.install
            progress = .ready(version)
        }
    }

    private func swap(_ version: AppVersion, _ step: UpdateStep, silent: Bool) {
        readyInstall = nil
        // Stored before the swap starts, because the swap quits this app and only the next launch can report it.
        defaults.set(version.description, forKey: Self.swappingToKey)
        progress = .installing(version)
        do {
            try runner.install(step, log: logFile) { status in
                Task { @MainActor in self.installEnded(version, status: status, silent: silent) }
            }
        } catch {
            installEnded(version, status: -1, silent: silent)
        }
    }

    /// A zero exit seen from here means install.sh missed this copy when quitting (a path spelled differently) but
    /// opened the new one, so this copy quits to leave one running. A non-zero exit leaves this copy installed, except
    /// when both renames fail, which install.sh reports in the log with where the old app was left.
    private func installEnded(_ version: AppVersion, status: Int32, silent: Bool) {
        guard progress == .installing(version) else { return }
        guard status != 0 else { return quit() }
        defaults.set(nil, forKey: Self.swappingToKey)
        fail(version, .install, silent: silent)
    }

    private func fail(_ version: AppVersion, _ failure: UpdateFailure, silent: Bool) {
        progress = .failed(version, failure)
        if silent { onCouldNotUpdate(version) }
    }

    private func prepare() throws {
        try AppPaths.createOwnerOnlyDirectory(paths.supportDirectory)
        if FileManager.default.fileExists(atPath: paths.updateStageDirectory.path) {
            try FileManager.default.removeItem(at: paths.updateStageDirectory)
        }
        try Data().write(to: paths.updateLogFile)
    }
}
