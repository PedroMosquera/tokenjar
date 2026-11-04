import Foundation

public enum UpdateMethod: Equatable, Sendable {
    case homebrew(prefix: String)
    case releaseArchive
}

/// The shell line that updates Tokenjar. Homebrew's copy is updated through Homebrew; every other install gets the
/// release archive through the get.sh shipped inside the running app, so no script is downloaded to run the update.
/// The tagged source it builds does run its own Makefile and scripts.
public enum UpdateCommand {
    static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]
    public static let terminalScriptFileName = "tokenjar-update.command"

    public static func method(fileExists: (String) -> Bool) -> UpdateMethod {
        homebrewPrefixes.first { fileExists("\($0)/opt/tokenjar/Tokenjar.app") }.map { .homebrew(prefix: $0) } ?? .releaseArchive
    }

    /// The running app's own folder, so the copy replaced is the one running. A copy running from inside Homebrew's
    /// folders goes to ~/Applications instead: replacing Homebrew's own app in place deletes it whenever brew has
    /// nothing to upgrade, because the install script then copies the app onto itself.
    public static func installFolder(appBundle: String, home: String) -> String {
        if homebrewPrefixes.contains(where: { appBundle.hasPrefix("\($0)/Cellar/") || appBundle.hasPrefix("\($0)/opt/") }) {
            return "\(home)/Applications"
        }
        return (appBundle as NSString).deletingLastPathComponent
    }

    public static func terminal(method: UpdateMethod, version: AppVersion, appBundle: String, home: String) -> String {
        let folder = SignInCommand.shellQuote(installFolder(appBundle: appBundle, home: home))
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
