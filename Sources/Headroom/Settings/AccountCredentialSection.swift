import SwiftUI
import HeadroomCore

/// Where an OpenCode account's API key comes from. The stored key is never read back or shown: the field only accepts
/// a new key. The Keychain changes only on Save Key, and on a confirmed switch back to auth.json, which deletes the key.
struct AccountCredentialSection: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    private enum Source: Hashable { case authFile, keychain }

    @SettingsState private var choosingKeychain = false
    @SettingsState private var confirmRemoveKey = false
    @SettingsState private var draftKey = ""
    @SettingsState private var message: (text: String, isError: Bool)?

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
            Picker("API key", selection: source) {
                Text("From opencode's auth.json").tag(Source.authFile)
                Text("Pasted key, saved in Headroom's Keychain item").tag(Source.keychain)
            }
            .pickerStyle(.radioGroup)
            .confirmationDialog("Stop using the pasted key?", isPresented: $confirmRemoveKey) {
                Button("Delete Key", role: .destructive, action: removePastedKey)
            } message: {
                Text("Headroom will read opencode's auth.json and delete the pasted key from this Mac's Keychain.")
            }

            if source.wrappedValue == .authFile {
                HelpText("Reads \(authFileDescription). Sign in with opencode auth login to add or change it.")
            } else {
                // config.json syncs between Macs and the Keychain does not, so a .keychain reference does not prove a key is here.
                SecureField("New API key", text: $draftKey, prompt: Text(isKeychain ? "Paste a key to use on this Mac" : "Paste an OpenCode API key"))
                HStack {
                    if let message {
                        Text(message.text).font(.callout).foregroundStyle(message.isError ? .red : .secondary)
                    }
                    Spacer()
                    Button("Save Key", action: saveKey)
                        .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            Text("Credential")
        } footer: {
            HelpText.footer("Keys never go into config.json. A pasted key lives only in this Mac's Keychain, under Headroom's own item, so paste it again on each Mac that shares this config.")
        }
    }

    private var authFileDescription: String {
        if case .file(let path, let key) = account.credential { return "the \(key) entry of \(path)" }
        return "the opencode-go entry of ~/.local/share/opencode/auth.json, then opencode"
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainSecretStore().write(key, account: account.id)
            draftKey = ""
            choosingKeychain = false
            model.updateAccount(account.id) { $0.credential = .keychain(account: account.id) }
            message = ("Saved to the Keychain.", false)
        } catch SecretStoreError.keychain(let status) {
            message = ("Keychain refused the key (status \(status)).", true)
        } catch {
            message = ("Keychain refused the key.", true)
        }
    }

    private func removePastedKey() {
        do {
            let remaining = try SettingsLogic.removingPastedKey(from: account.credential, secrets: KeychainSecretStore())
            draftKey = ""
            choosingKeychain = false
            model.updateAccount(account.id) { $0.credential = remaining }
        } catch SecretStoreError.keychain(let status) {
            message = ("Keychain refused to delete the key (status \(status)).", true)
        } catch {
            message = ("Keychain refused to delete the key.", true)
        }
    }
}
