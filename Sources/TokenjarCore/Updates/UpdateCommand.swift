import Foundation

public enum UpdateMethod: Equatable, Sendable {
    case homebrew(prefix: String)
    case releaseArchive
}

/// The shell line that updates Tokenjar. Homebrew's copy is updated through Homebrew; every other install gets the
/// release archive through the get.sh shipped inside the running app, so nothing fetched at update time is run.
public enum UpdateCommand {
    static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]
    public static let terminalScriptFileName = "tokenjar-update.command"

    public static func method(fileExists: (String) -> Bool) -> UpdateMethod {
        homebrewPrefixes.first { fileExists("\($0)/opt/tokenjar/Tokenjar.app") }.map { .homebrew(prefix: $0) } ?? .releaseArchive
    }

    /// `installFolder` is the folder holding the running app, so the copy replaced is the one that is running.
    public static func terminal(method: UpdateMethod, version: AppVersion, appBundle: String, installFolder: String) -> String {
        let folder = SignInCommand.shellQuote(installFolder)
        switch method {
        case .homebrew(let prefix):
            let brew = SignInCommand.shellQuote("\(prefix)/bin/brew")
            let install = SignInCommand.shellQuote("\(prefix)/bin/tokenjar-install-app")
            return "\(brew) upgrade tokenjar && \(install) \(folder)"
        case .releaseArchive:
            let script = SignInCommand.shellQuote("\(appBundle)/Contents/Resources/get.sh")
            return "TOKENJAR_VERSION=\(version) /bin/bash \(script) \(folder)"
        }
    }
}
