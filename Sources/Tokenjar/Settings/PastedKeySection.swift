import OSLog
import SwiftUI
import TokenjarCore

/// The key of a provider whose only source is a key pasted here. The stored key is never read back or shown: the field
/// only accepts a new one.
struct PastedKeySection: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    @SettingsState private var confirmRemoveKey = false
    @SettingsState private var draftKey = ""
    @SettingsState private var message: (text: String, isError: Bool)?

    private static let log = Logger(subsystem: AppPaths.bundleIdentifier, category: "keychain")

    private var hasKeychainKey: Bool {
        if case .keychain = account.credential { return true }
        return false
    }

    private var prompt: String {
        switch account.provider {
        case .glm: "Paste a GLM Coding Plan API key"
        default: "Paste an API key"
        }
    }

    var body: some View {
        Section {
            LabeledContent {
                EmptyView()
            } label: {
                Text("API key")
                Text("Never saved in config.json. A pasted key stays in this Mac's Keychain, so paste it again on each Mac.")
            }
            // config.json syncs between Macs and the Keychain does not, so a .keychain reference does not prove a key is here.
            SecureField("New API key", text: $draftKey, prompt: Text(hasKeychainKey ? "Paste a key to use on this Mac" : prompt))
            HStack {
                if let message {
                    if message.isError {
                        SettingsNotice(kind: .error, text: message.text)
                    } else {
                        Text(message.text).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if hasKeychainKey {
                    Button("Remove Key", role: .destructive) { confirmRemoveKey = true }
                }
                Button("Save Key", action: saveKey)
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Remove the pasted key?", isPresented: $confirmRemoveKey) {
                Button("Delete Key", role: .destructive, action: removeKey)
            } message: {
                Text("Tokenjar deletes the key from this Mac's Keychain and stops checking \(account.provider.displayName) until you paste another.")
            }
        } header: {
            Text("Credential")
        }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.savePastedKey(key, accountID: account.id)
            draftKey = ""
            message = ("Saved to the Keychain.", false)
        } catch {
            Self.log.error("Saving the pasted key failed: \(String(describing: error), privacy: .public)")
            message = ("Couldn't save the key to the Keychain. Unlock the login keychain and try again.", true)
        }
    }

    private func removeKey() {
        do {
            let remaining = try SettingsLogic.removingPastedKey(from: account.credential, secrets: model.secrets)
            draftKey = ""
            message = nil
            model.updateAccount(account.id) { $0.credential = remaining }
        } catch {
            Self.log.error("Deleting the pasted key failed: \(String(describing: error), privacy: .public)")
            message = ("Couldn't delete the key from the Keychain. Unlock the login keychain and try again.", true)
        }
    }
}
