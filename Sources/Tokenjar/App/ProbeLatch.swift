import CryptoKit
import Foundation
import TokenjarCore

/// Accounts whose `/usage` probe ran as a model turn instead of answering locally: `claude -p /usage` spent tokens
/// or `agy -p /usage` spent quota. Hard rule 5 forbids starting a model turn, so a latched account is not probed
/// again by any path until that CLI's binary changes or the user asks for one more try. Persisted, so a relaunch
/// does not probe again either.
nonisolated struct ProbeLatch: Codable, Equatable {
    /// A CLI whose `/usage` probe can turn into a model turn. The raw value is the name `CLILocator` looks up.
    enum CLI: String, Codable, CaseIterable {
        case claude, agy

        /// Thrown by the fetcher when the probe turned into a model turn, and shown on the card while latched.
        var modelTurnError: FetchError {
            switch self {
            case .claude: .unsupported(ClaudeUsageFetcher.modelTurnMessage)
            case .agy: .unsupported(AntigravityUsageFetcher.modelTurnMessage)
            }
        }

        /// nil for every failure that did not start a model turn.
        init?(modelTurn error: FetchError) {
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

    private var entries: [String: Entry] = [:]

    /// True when a fetch failed because its probe ran as a model turn, whichever CLI it was.
    static func spentTokens(_ error: FetchError) -> Bool {
        CLI(modelTurn: error) != nil
    }

    var isEmpty: Bool { entries.isEmpty }
    var accountIDs: [String] { entries.keys.sorted() }

    /// SHA-256 of the resolved path, size and modification date. The native installer resolves to a per-version
    /// path and npm rewrites the file, so either kind of update changes it. Hashed because the path holds the
    /// user's home folder name.
    static func fingerprint(ofBinaryAt url: URL?) -> String? {
        guard let url else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(resolved.path)|\(size)|\(modified)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isLatched(_ accountID: String) -> Bool {
        entries[accountID] != nil
    }

    /// nil when the account is not latched.
    func cli(of accountID: String) -> CLI? {
        entries[accountID]?.owner
    }

    mutating func latch(_ accountID: String, cli: CLI, binary: String?) {
        entries[accountID] = Entry(binary: binary, cli: cli)
    }

    /// Returns whether the account was latched.
    @discardableResult
    mutating func release(_ accountID: String) -> Bool {
        entries.removeValue(forKey: accountID) != nil
    }

    /// Releases the accounts latched on another build of their CLI: an update may have fixed `/usage`.
    /// `current` gives the fingerprint of a CLI's binary today. Returns whether anything was released.
    mutating func releaseAll(unlessBinary current: (CLI) -> String?) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value.binary == current($0.value.owner) }
        return entries.count != before
    }
}
