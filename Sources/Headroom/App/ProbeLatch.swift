import CryptoKit
import Foundation
import HeadroomCore

/// Accounts whose `claude -p /usage` ran as a billed model turn instead of answering locally. Hard rule 5 forbids
/// starting a model turn, so a latched account is not probed again by any path until the claude binary changes
/// or the user asks for one more try. Persisted, so a relaunch does not probe again either.
nonisolated struct ProbeLatch: Codable, Equatable {
    static let error = FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)

    private struct Entry: Codable, Equatable {
        /// Fingerprint of the claude binary the turn ran with; nil when it could not be located.
        var binary: String?
    }

    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var accountIDs: [String] { entries.keys.sorted() }

    static func spentTokens(_ error: FetchError) -> Bool {
        error == Self.error
    }

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

    mutating func latch(_ accountID: String, binary: String?) {
        entries[accountID] = Entry(binary: binary)
    }

    /// Returns whether the account was latched.
    @discardableResult
    mutating func release(_ accountID: String) -> Bool {
        entries.removeValue(forKey: accountID) != nil
    }

    /// Releases the accounts latched on another claude build: an update may have fixed `/usage`.
    /// Returns whether anything was released.
    mutating func releaseAll(unlessBinary current: String?) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value.binary == current }
        return entries.count != before
    }
}
