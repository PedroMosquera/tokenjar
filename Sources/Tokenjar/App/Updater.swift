import Foundation
import Observation
import TokenjarCore

enum UpdateFailure: Equatable {
    case couldNotStart, build, homebrewBehind, install
}

enum UpdateProgress: Equatable {
    case idle
    case building(AppVersion)
    /// The swap has started and quits this app; the next launch reports how it went.
    case installing(AppVersion)
    case failed(AppVersion, UpdateFailure)
}

protocol UpdateRunning: Sendable {
    /// Runs `step` to its end with its output appended to `log`, and returns its exit status.
    func build(_ step: UpdateStep, log: URL) async -> Int32
    /// Starts `step` with its output appended to `log` and returns at once. The process outlives this app, which it
    /// normally quits; `onExit` runs only when the app is still running as it ends.
    func install(_ step: UpdateStep, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws
}

/// Update Now: builds the new version without touching the installed app, then starts the swap, which quits this app
/// and opens the new one. A failed build leaves this app running as it is.
@MainActor @Observable
final class Updater {
    static let swappingToKey = "updateSwappingTo"

    private(set) var progress: UpdateProgress = .idle
    /// Nil until checked.
    private(set) var commandLineTools: Bool?

    /// Called once, on the first launch after a swap that installed this version.
    @ObservationIgnored var onUpdated: (AppVersion) -> Void = { _ in }
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
    }

    var blocker: UpdateBlocker? {
        UpdateBlocker.check(appBundle: appBundle, folderWritable: folderWritable, commandLineTools: commandLineTools)
    }

    var isBusy: Bool {
        switch progress {
        case .building, .installing: true
        case .idle, .failed: false
        }
    }

    var logFile: URL { paths.updateLogFile }

    @discardableResult
    func refreshPrerequisites() -> Task<Void, Never> {
        let toolsInstalled = toolsInstalled
        return Task { commandLineTools = await toolsInstalled() }
    }

    @discardableResult
    func start(_ version: AppVersion) -> Task<Void, Never>? {
        guard !isBusy, blocker == nil else { return nil }
        let method = UpdateCommand.method(fileExists: fileExists)
        let plan = UpdatePlan.make(
            method: method, version: version, appBundle: appBundle, home: paths.home.path,
            stageDirectory: paths.updateStageDirectory.path, temporaryDirectory: temporaryDirectory
        )
        do {
            try prepare()
        } catch {
            progress = .failed(version, .couldNotStart)
            return nil
        }
        progress = .building(version)
        let runner = runner, log = logFile
        return Task {
            guard await runner.build(plan.build, log: log) == 0 else {
                progress = .failed(version, .build)
                return
            }
            // brew upgrade succeeds without upgrading when its tap has not seen the release yet.
            if case .homebrew(let prefix) = method, !(kegVersion(prefix).map { $0 >= version } ?? false) {
                progress = .failed(version, .homebrewBehind)
                return
            }
            // Stored before the swap starts, because the swap quits this app and only the next launch can report it.
            defaults.set(version.description, forKey: Self.swappingToKey)
            progress = .installing(version)
            do {
                try runner.install(plan.install, log: log) { status in
                    Task { @MainActor in self.installEnded(version, status: status) }
                }
            } catch {
                installEnded(version, status: -1)
            }
        }
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
        case nil:
            break
        }
    }

    /// A zero exit seen from here means install.sh missed this copy when quitting (a path spelled differently) but
    /// opened the new one, so this copy quits to leave one running. A non-zero exit leaves this copy installed, except
    /// when both renames fail, which install.sh reports in the log with where the old app was left.
    private func installEnded(_ version: AppVersion, status: Int32) {
        guard progress == .installing(version) else { return }
        guard status != 0 else { return quit() }
        defaults.set(nil, forKey: Self.swappingToKey)
        progress = .failed(version, .install)
    }

    private func prepare() throws {
        try AppPaths.createOwnerOnlyDirectory(paths.supportDirectory)
        if FileManager.default.fileExists(atPath: paths.updateStageDirectory.path) {
            try FileManager.default.removeItem(at: paths.updateStageDirectory)
        }
        try Data().write(to: paths.updateLogFile)
    }
}
