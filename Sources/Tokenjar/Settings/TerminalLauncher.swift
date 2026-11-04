import AppKit
import TokenjarCore

/// Hands a command to Terminal through a .command file: no AppleScript, so no automation permission.
enum TerminalLauncher {
    static func signIn(command: String, account: AccountConfig) throws {
        try run(
            command: command, title: "sign in to \(account.provider.displayName) (\(account.label))",
            fileName: SignInCommand.scriptFileName(accountID: account.id)
        )
    }

    static func run(command: String, title: String, fileName: String) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: fileName)
        try Data(SignInCommand.script(command: command, title: title).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    }

    static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
