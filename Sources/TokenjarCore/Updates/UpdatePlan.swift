import Foundation

/// One process an update runs.
public struct UpdateStep: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// Update Now in two steps, so the swap can wait: `build` leaves the installed app alone and `install` replaces the
/// running copy. Like Update in Terminal, the archive path runs only the get.sh bundled in the running app.
public struct UpdatePlan: Equatable, Sendable {
    public var build: UpdateStep
    public var install: UpdateStep

    /// `temporaryDirectory` is the app's own TMPDIR, kept so builds use the per-user folder rather than /tmp.
    public static func make(
        method: UpdateMethod, version: AppVersion, appBundle: String, home: String, stageDirectory: String,
        temporaryDirectory: String?
    ) -> UpdatePlan {
        let folder = (appBundle as NSString).deletingLastPathComponent
        // A GUI app has no shell PATH, so the tools the scripts call are found only in these folders.
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home]
        if let temporaryDirectory { environment["TMPDIR"] = temporaryDirectory }
        switch method {
        case .homebrew(let prefix):
            environment["PATH"] = "\(prefix)/bin:" + environment["PATH"]!
            return UpdatePlan(
                build: UpdateStep(executable: "\(prefix)/bin/brew", arguments: ["upgrade", "tokenjar"], environment: environment),
                install: UpdateStep(executable: "\(prefix)/bin/tokenjar-install-app", arguments: [folder], environment: environment)
            )
        case .releaseArchive:
            var build = environment, install = environment
            build["TOKENJAR_VERSION"] = version.description
            build["TOKENJAR_STAGE_DIR"] = stageDirectory
            install["TOKENJAR_APP"] = "\(stageDirectory)/Tokenjar.app"
            return UpdatePlan(
                build: UpdateStep(executable: "/bin/bash", arguments: ["\(appBundle)/Contents/Resources/get.sh"], environment: build),
                install: UpdateStep(executable: "/bin/bash", arguments: ["\(stageDirectory)/install.sh", folder], environment: install)
            )
        }
    }
}

/// Why Update Now cannot start. Update in Terminal stays available in every case.
public enum UpdateBlocker: Equatable, Sendable {
    /// Replacing a copy inside Homebrew's folders deletes it when brew has nothing to upgrade.
    case runsFromHomebrew
    /// install.sh replaces Tokenjar.app, so a renamed copy would keep running beside the new one.
    case renamed(String)
    case folderNotWritable(String)
    case noCommandLineTools

    /// `commandLineTools` is nil until checked, and an unchecked Mac is not blocked: get.sh stops at once without them.
    public static func check(appBundle: String, folderWritable: (String) -> Bool, commandLineTools: Bool?) -> UpdateBlocker? {
        let folder = (appBundle as NSString).deletingLastPathComponent
        if UpdateCommand.runsFromHomebrew(appBundle) { return .runsFromHomebrew }
        let name = (appBundle as NSString).lastPathComponent
        if name != "Tokenjar.app" { return .renamed(name) }
        if !folderWritable(folder) { return .folderNotWritable(folder) }
        if commandLineTools == false { return .noCommandLineTools }
        return nil
    }

    public var message: String {
        switch self {
        case .runsFromHomebrew: "This copy runs from Homebrew's folder. Update in Terminal installs the new version into ~/Applications."
        case .renamed(let name): "Update Now replaces Tokenjar.app, and this copy is named \(name)."
        case .folderNotWritable(let folder): "Tokenjar can't write to \(folder), so it can't replace itself there."
        case .noCommandLineTools: "The Command Line Tools are not installed. Run xcode-select --install, then try again."
        }
    }
}

/// What the launch after a swap finds, from the version the swap was installing and the version now running.
public enum SwapOutcome: Equatable, Sendable {
    case updated(AppVersion)
    /// install.sh reopens the old app when it cannot put the new one in place.
    case failed(AppVersion)

    /// Nil when no swap was pending, or a newer version is running than the one the swap installed.
    public static func after(swappingTo: AppVersion?, installed: AppVersion?) -> SwapOutcome? {
        guard let swappingTo, let installed else { return nil }
        if installed == swappingTo { return .updated(swappingTo) }
        return installed < swappingTo ? .failed(swappingTo) : nil
    }
}
