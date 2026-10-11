import Foundation

/// The provider's own login command for an account. Tokenjar never signs in itself: the CLI owns its credentials.
public enum SignInCommand {
    /// Where to send people for Antigravity, whose CLI has no login command Tokenjar can hand off to.
    public static let antigravityInstallURL = URL(string: "https://antigravity.google")!

    public static func profileVariable(for provider: ProviderID) -> (name: String, defaultPath: String)? {
        switch provider {
        case .claude: ("CLAUDE_CONFIG_DIR", "~/.claude")
        case .codex: ("CODEX_HOME", "~/.codex")
        case .opencodeGo, .opencodeZen, .antigravity: nil
        }
    }

    /// nil for Antigravity. `executable` maps a CLI name to what should run (a located absolute path, or the bare name).
    public static func command(for account: AccountConfig, paths: AppPaths, executable: (String) -> String) -> String? {
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
    public static func shellQuote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A .command script for Terminal. It deletes itself first so no copy lingers in the temporary folder.
    public static func script(command: String, title: String) -> String {
        """
        #!/bin/sh
        rm -f "$0"
        echo \(shellQuote("Tokenjar: \(title)"))
        echo
        \(command)

        """
    }

    /// File name built only from the id's slug characters, so a hand-edited id cannot point outside the temp folder.
    public static func scriptFileName(accountID: String) -> String {
        let slug = String(accountID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(Character.init))
        return "tokenjar-sign-in-\(slug.isEmpty ? "account" : slug).command"
    }
}
