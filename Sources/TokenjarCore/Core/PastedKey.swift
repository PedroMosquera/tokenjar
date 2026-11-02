import Foundation

/// The key for a provider whose only source is one pasted in Settings. There is no fallback to environment variables or
/// other apps' files: a missing key is `FetchError.notSignedIn`.
enum PastedKey {
    /// `.file` exists only for `--capture`, which takes a key through `--credential-file`; Settings never writes one.
    static func apiKey(for account: AccountConfig, secrets: any SecretStore, paths: AppPaths) throws -> String {
        let key: String?
        switch account.credential {
        case .keychain(let name): key = try secrets.pastedKey(account: name)
        case .file(let path, let entry): key = OpenCodeLocalData.apiKey(inAuthFile: paths.expand(path), entries: [entry])
        case nil: key = nil
        }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw FetchError.notSignedIn }
        return key
    }
}
