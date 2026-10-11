import OSLog
import SwiftUI
import TokenjarCore

/// Where an OpenCode account's API key comes from. The stored key is never read back or shown: the field only accepts
/// a new key. The Keychain changes only on Save Key, and on a confirmed switch back to auth.json, which deletes the key.
struct AccountCredentialSection: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    /// opencode's own login, which writes auth.json; offered only while the key comes from there.
    var signInCommand: String?
    var onSignIn: (String) -> Void

    private enum Source: Hashable { case authFile, keychain }

    @SettingsState private var choosingKeychain = false
    @SettingsState private var confirmRemoveKey = false
    @SettingsState private var draftKey = ""
    @SettingsState private var message: (text: String, isError: Bool)?

    private static let log = Logger(subsystem: AppPaths.bundleIdentifier, category: "keychain")

    private var isKeychain: Bool {
        if case .keychain = account.credential { return true }
        return false
    }

    private var source: Binding<Source> {
        Binding(
            get: { isKeychain || choosingKeychain ? .keychain : .authFile },
            set: { newValue in
                message = nil
                switch newValue {
                case .keychain:
                    choosingKeychain = true
                case .authFile:
                    if isKeychain { confirmRemoveKey = true } else { choosingKeychain = false }
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker(selection: source) {
                Text("opencode's auth.json").tag(Source.authFile)
                Text("Pasted key").tag(Source.keychain)
            } label: {
                Text("API key")
                Text("Never saved in config.json. A pasted key stays in this Mac's Keychain, so paste it again on each Mac.")
            }
            .confirmationDialog("Stop using the pasted key?", isPresented: $confirmRemoveKey) {
                Button("Delete Key", role: .destructive, action: removePastedKey)
            } message: {
                Text("Tokenjar will read opencode's auth.json and delete the pasted key from this Mac's Keychain.")
            }

            if source.wrappedValue == .authFile {
                if let command = signInCommand {
                    TextRow {
                        Text(command)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(command)
                        Text(authFileHelp)
                    }
                    HStack {
                        Spacer()
                        Button("Copy Command") { SignInLauncher.copy(command) }
                        Button("Sign In in Terminal\u{2026}") { onSignIn(command) }
                    }
                } else {
                    TextRow { Text(authFileHelp) }
                }
            } else {
                // config.json syncs between Macs and the Keychain does not, so a .keychain reference does not prove a key is here.
                SecureField("New API key", text: $draftKey, prompt: Text(isKeychain ? "Paste a key to use on this Mac" : "Paste an OpenCode API key"))
                HStack {
                    if let message {
                        if message.isError {
                            SettingsNotice(kind: .error, text: message.text)
                        } else {
                            Text(message.text).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Save Key", action: saveKey)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            Text("Credential")
        }
    }

    private var authFileHelp: String {
        if case .file(let path, let key) = account.credential {
            return "Uses the key opencode saved when you signed in (\(path), entry \(key))."
        }
        let file = SettingsLogic.tildePath(AccountDiscovery.openCodeAuthFile(paths: model.paths).path, home: model.paths.home.path)
        return "Uses the key opencode saved when you signed in (\(file), entry opencode-go, else opencode)."
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.secrets.write(key, account: account.id)
            draftKey = ""
            choosingKeychain = false
            model.updateAccount(account.id) { $0.credential = .keychain(account: account.id) }
            message = ("Saved to the Keychain.", false)
        } catch {
            Self.log.error("Saving the pasted key failed: \(String(describing: error), privacy: .public)")
            message = ("Couldn't save the key to the Keychain. Unlock the login keychain and try again.", true)
        }
    }

    private func removePastedKey() {
        do {
            let remaining = try SettingsLogic.removingPastedKey(from: account.credential, secrets: model.secrets)
            draftKey = ""
            choosingKeychain = false
            model.updateAccount(account.id) { $0.credential = remaining }
        } catch {
            Self.log.error("Deleting the pasted key failed: \(String(describing: error), privacy: .public)")
            message = ("Couldn't delete the key from the Keychain. Unlock the login keychain and try again.", true)
        }
    }
}
