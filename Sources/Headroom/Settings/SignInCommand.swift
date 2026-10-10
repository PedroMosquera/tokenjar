import AppKit
import HeadroomCore

/// The provider's own login command for an account. Headroom never signs in itself: the CLI owns its credentials.
nonisolated enum SignInCommand {
    /// Where to send people for Antigravity, whose CLI has no login command Headroom can hand off to.
    static let antigravityInstallURL = URL(string: "https://antigravity.google")!

    static func profileVariable(for provider: ProviderID) -> (name: String, defaultPath: String)? {
        switch provider {
        case .claude: ("CLAUDE_CONFIG_DIR", "~/.claude")
        case .codex: ("CODEX_HOME", "~/.codex")
        case .opencodeGo, .opencodeZen, .antigravity: nil
        }
    }

    /// nil for Antigravity. `executable` maps a CLI name to what should run (a located absolute path, or the bare name).
    static func command(for account: AccountConfig, paths: AppPaths, executable: (String) -> String) -> String? {
        let words: [String]
        switch account.provider {
        case .claude: words = [executable("claude"), "auth", "login"]
        case .codex: words = [executable("codex"), "login"]
        case .opencodeGo, .opencodeZen: words = [executable("opencode"), "auth", "login"]
        case .antigravity: return nil
        }
        var parts = words.map(shellQuote)
        if let variable = profileVariable(for: account.provider), let dir = SettingsLogic.profileDir(from: account.profileDir ?? "") {
            // Expanded here because a quoted ~ is not expanded by the shell.
            parts.insert("\(variable.name)=\(shellQuote(paths.expand(dir).path))", at: 0)
        }
        return parts.joined(separator: " ")
    }

    /// POSIX single-quoting. Words made only of safe characters stay bare so the common case reads naturally.
    static func shellQuote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A .command script for Terminal. It deletes itself first so no copy lingers in the temporary folder.
    static func script(command: String, title: String) -> String {
        """
        #!/bin/sh
        rm -f "$0"
        echo \(shellQuote("Headroom: \(title)"))
        echo
        \(command)

        """
    }

    /// File name built only from the id's slug characters, so a hand-edited id cannot point outside the temp folder.
    static func scriptFileName(accountID: String) -> String {
        let slug = String(accountID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(Character.init))
        return "headroom-sign-in-\(slug.isEmpty ? "account" : slug).command"
    }
}

/// Hands the login command to Terminal through a .command file: no AppleScript, so no automation permission.
enum SignInLauncher {
    static func run(command: String, account: AccountConfig) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: SignInCommand.scriptFileName(accountID: account.id))
        let script = SignInCommand.script(command: command, title: "sign in to \(account.provider.displayName) (\(account.label))")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
