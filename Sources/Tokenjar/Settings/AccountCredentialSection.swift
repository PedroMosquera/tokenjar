import SwiftUI
import TokenjarCore

/// Where an OpenCode Go account's API key comes from: the auth.json opencode's own login writes. Tokenjar stores no key.
struct AccountCredentialSection: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var signInCommand: SignInLine?
    var onSignIn: (String) -> Void

    var body: some View {
        Section {
            TextRow {
                Text("Key file")
                // One line: a wrapped path breaks at a slash and reads like two paths. The tooltip has it whole.
                Text(keyFile.path)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(keyFile.path), \(keyFile.entry)")
            }
            if let line = signInCommand {
                TextRow {
                    Text(line.shown)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line.shown)
                    Text("Runs opencode's own login in Terminal. Tokenjar reads the key it saves.")
                }
                HStack {
                    Spacer()
                    Button("Copy Command") { TerminalLauncher.copy(line.command) }
                    Button("Sign In in Terminal\u{2026}") { onSignIn(line.command) }
                }
            }
        } header: {
            Text("Credential")
        }
    }

    private var keyFile: (path: String, entry: String) {
        Self.keyFile(for: account, paths: model.paths, previewMode: model.previewMode, environment: ProcessInfo.processInfo.environment)
    }

    /// A preview render ignores `environment`, so the local `XDG_DATA_HOME` never reaches a README image.
    static func keyFile(for account: AccountConfig, paths: AppPaths, previewMode: Bool, environment: [String: String]) -> (path: String, entry: String) {
        if case .file(let path, let key) = account.credential {
            return (path, "entry \(key)")
        }
        let file = AccountDiscovery.openCodeAuthFile(paths: paths, environment: previewMode ? [:] : environment)
        return (SettingsLogic.tildePath(file.path, home: paths.home.path), "entry opencode-go, else opencode")
    }
}
