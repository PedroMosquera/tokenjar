import AppKit
import HeadroomCore

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
