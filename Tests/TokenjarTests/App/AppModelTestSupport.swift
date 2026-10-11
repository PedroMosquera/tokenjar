import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

/// A throwaway home, so AppModel tests never read or write the real ~/.config/tokenjar or Application Support.
struct ModelHome {
    let url: URL
    var paths: AppPaths { AppPaths(home: url) }
    var configFile: URL { paths.configFile }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "tokenjar-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // XDG_CONFIG_HOME in the test environment would point the config at a real directory.
        try #require(AppPaths(home: url).configFile.path.hasPrefix(url.path))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: relative), withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> URL {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// A file CLILocator accepts as a CLI. Tests inject fetchers, so it is never run.
    func makeExecutable(_ relative: String, contents: String = "#!/bin/sh\nexit 1\n") throws -> URL {
        let file = try write(relative, contents)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    func writeConfig(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try encoder.encode(config).write(to: configFile)
    }

    func readConfig() throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configFile))
    }

    func mode(_ file: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    }

    func isSymlink(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}

/// Fetches run on task-group threads, hence the lock.
nonisolated final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ id: String) { lock.withLock { ids.append(id) } }
    func count(_ id: String) -> Int { lock.withLock { ids.filter { $0 == id }.count } }
}

/// Holds fetches until the test opens it, to observe the model while a fetch is running.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

nonisolated struct FakeFetcher: UsageFetcher {
    var log: FetchLog
    var gate: Gate?
    var result: @Sendable (AccountConfig) -> Result<UsageSnapshot, FetchError>

    func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        log.record(account.id)
        if let gate { await gate.wait() }
        return try result(account).get()
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_791_660_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

nonisolated func usageSnapshot(_ account: AccountConfig, plan: String? = nil, fetchedAt: Date = Date()) -> UsageSnapshot {
    UsageSnapshot(
        accountID: account.id, provider: account.provider, plan: plan,
        windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 10, windowMinutes: 300, resetsAt: fetchedAt.addingTimeInterval(3600))],
        fetchedAt: fetchedAt, source: "test"
    )
}

/// Polls instead of sleeping a fixed time; records an issue rather than hanging when the condition never holds.
@MainActor
func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition did not hold within 3 s", sourceLocation: sourceLocation)
}

/// Stands in for the Keychain: counts reads and refuses with any status, as a Deny on the prompt does.
nonisolated final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var refusal: OSStatus?
    private var reads = 0

    init(_ values: [String: String] = [:]) { self.values = values }

    var readCount: Int { lock.withLock { reads } }
    func refuse(with status: OSStatus?) { lock.withLock { refusal = status } }

    func read(account: String) throws -> String? {
        try lock.withLock {
            reads += 1
            if let refusal { throw SecretStoreError.keychain(refusal) }
            return values[account]
        }
    }

    func write(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// Reads a pasted key through the context the way the OpenCode Go fetcher does, and logs each key it was given.
nonisolated struct PastedKeyFetcher: UsageFetcher {
    var keys: FetchLog

    func fetch(_ account: AccountConfig, context: FetchContext) async throws -> UsageSnapshot {
        guard case .keychain(let name) = account.credential, let key = try? context.secrets.read(account: name) else {
            throw FetchError.notSignedIn
        }
        keys.record(key)
        return usageSnapshot(account)
    }
}
