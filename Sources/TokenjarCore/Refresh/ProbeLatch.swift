import Foundation

/// Accounts whose `/usage` probe ran as a model turn instead of answering locally: `claude -p /usage` spent tokens
/// or `agy -p /usage` spent quota. Hard rule 5 forbids starting a model turn, so a latched account is not probed
/// again by any path until that CLI's binary changes or the user asks for one more try. Persisted, so a relaunch
/// does not probe again either.
public struct ProbeLatch: Codable, Equatable, Sendable {
    /// A CLI whose `/usage` probe can turn into a model turn. The raw value is the name `CLILocator` looks up.
    public enum CLI: String, Codable, CaseIterable, Sendable {
        case claude, agy

        /// Thrown by the fetcher when the probe turned into a model turn, and shown on the card while latched.
        public var modelTurnError: FetchError {
            switch self {
            case .claude: .unsupported(ClaudeUsageFetcher.modelTurnMessage)
            case .agy: .unsupported(AntigravityUsageFetcher.modelTurnMessage)
            }
        }

        /// nil for every failure that did not start a model turn.
        public init?(modelTurn error: FetchError) {
            guard let cli = Self.allCases.first(where: { $0.modelTurnError == error }) else { return nil }
            self = cli
        }
    }

    private struct Entry: Codable, Equatable {
        /// Fingerprint of the CLI binary the turn ran with; nil when it could not be located.
        var binary: String?
        /// nil in files written before agy could latch, when every entry was claude's.
        var cli: CLI?
        var owner: CLI { cli ?? .claude }
    }

    /// Inside `AppPaths.supportDirectory`.
    public static let fileName = "probe-latch.json"

    private var entries: [String: Entry] = [:]

    public init() {}

    /// True when a fetch failed because its probe ran as a model turn, whichever CLI it was.
    public static func spentTokens(_ error: FetchError) -> Bool {
        CLI(modelTurn: error) != nil
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var accountIDs: [String] { entries.keys.sorted() }

    /// SHA-256 of the resolved path, size and modification date. The native installer resolves to a per-version
    /// path and npm rewrites the file, so either kind of update changes it. Hashed because the path holds the
    /// user's home folder name.
    public static func fingerprint(ofBinaryAt url: URL?) -> String? {
        guard let url else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return sha256Hex("\(resolved.path)|\(size)|\(modified)")
    }

    public func isLatched(_ accountID: String) -> Bool {
        entries[accountID] != nil
    }

    /// Whether running `cli` from the binary with fingerprint `binary` could repeat a turn the app latched, for any
    /// account. An entry without a fingerprint blocks every binary, since nothing shows which build it ran with.
    public func blocks(cli: CLI, binary: String?) -> Bool {
        entries.values.contains { $0.owner == cli && ($0.binary == nil || $0.binary == binary) }
    }

    /// nil when the account is not latched.
    public func cli(of accountID: String) -> CLI? {
        entries[accountID]?.owner
    }

    public mutating func latch(_ accountID: String, cli: CLI, binary: String?) {
        entries[accountID] = Entry(binary: binary, cli: cli)
    }

    /// Returns whether the account was latched.
    @discardableResult
    public mutating func release(_ accountID: String) -> Bool {
        entries.removeValue(forKey: accountID) != nil
    }

    /// Releases the accounts latched on another build of their CLI: an update may have fixed `/usage`.
    /// `current` gives the fingerprint of a CLI's binary today. Returns whether anything was released.
    public mutating func releaseAll(unlessBinary current: (CLI) -> String?) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value.binary == current($0.value.owner) }
        return entries.count != before
    }
}
