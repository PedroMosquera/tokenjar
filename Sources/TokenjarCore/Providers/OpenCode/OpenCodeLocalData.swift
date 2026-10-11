import Foundation

/// Where opencode keeps its files on this Mac, and how the Go API key is found among them.
enum OpenCodeLocalData {
    /// `account.profileDir` when set, else `$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`.
    static func dataDirectory(for account: AccountConfig, paths: AppPaths, environment: [String: String]) -> URL {
        if let dir = account.profileDir, !dir.isEmpty { return paths.expand(dir) }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appending(path: "opencode")
        }
        return paths.home.appending(path: ".local/share/opencode")
    }

    static func databaseFile(in dataDirectory: URL) -> URL { dataDirectory.appending(path: "opencode.db") }

    /// opencode's auth.json entries that may hold a Go key, most specific first.
    static let defaultAuthEntries = ["opencode-go", "opencode"]

    /// Resolves the API key for an OpenCode account. Missing key: `FetchError.notSignedIn`. From auth.json it decodes
    /// only the named entries and accepts only API-key and well-known logins, never OAuth ones (opencode's "openai").
    static func apiKey(for account: AccountConfig, secrets: any SecretStore, paths: AppPaths, dataDirectory: URL) throws -> String {
        let key: String?
        switch account.credential {
        case .file(let path, let entry):
            key = apiKey(inAuthFile: paths.expand(path), entries: [entry])
        case .keychain(let name):
            key = try? secrets.read(account: name)
        case nil:
            key = apiKey(inAuthFile: dataDirectory.appending(path: "auth.json"), entries: defaultAuthEntries)
        }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw FetchError.notSignedIn }
        return key
    }

    private static func apiKey(inAuthFile url: URL, entries names: [String]) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.userInfo[AuthEntries.namesKey] = names
        guard let file = try? decoder.decode(AuthEntries.self, from: data) else { return nil }
        for name in names {
            guard let entry = file.entries[name] else { continue }
            switch entry.type {
            case "api": if let key = entry.key { return key }
            // opencode stores the env var name in `key` and the secret in `token` for well-known logins.
            case "wellknown": if let token = entry.token { return token }
            default: continue
            }
        }
        return nil
    }

    /// Decodes only the entries named in `userInfo[namesKey]`, so other entries, including OAuth tokens,
    /// are never materialized.
    private struct AuthEntries: Decodable {
        static let namesKey = CodingUserInfoKey(rawValue: "tokenjar.authEntryNames")!

        struct Entry: Decodable {
            var type: String?
            var key: String?
            var token: String?
        }

        struct Name: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        var entries: [String: Entry] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Name.self)
            for name in decoder.userInfo[Self.namesKey] as? [String] ?? [] {
                entries[name] = try? container.decodeIfPresent(Entry.self, forKey: Name(stringValue: name))
            }
        }
    }
}
