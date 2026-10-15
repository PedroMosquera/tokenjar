import Foundation
@testable import TokenjarCore

enum TestPaths {
    static let target = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let fixtures = target.appending(path: "Fixtures")
    static let repository = target.deletingLastPathComponent().deletingLastPathComponent()
}

/// 2027-01-15 08:00 UTC. The clock for suites that only need a fixed instant; a suite's own `now` shadows it.
let now = Date(timeIntervalSince1970: 1_800_000_000)

/// The bytes of `Fixtures/<path>`.
func fixture(_ path: String) throws -> Data {
    try Data(contentsOf: TestPaths.fixtures.appending(path: path))
}

func fixtureText(_ path: String) throws -> String {
    String(decoding: try fixture(path), as: UTF8.self)
}

/// A fresh directory under the system temp folder, deleted on deinit. Keep the value alive (a local or a suite's
/// stored property) for as long as anything reads under it.
final class TemporaryDirectory: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(path: "tokenjar-tests/\(UUID().uuidString)")

    /// A failed create surfaces as the first write's error.
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    /// Restores the owner's write bit first, which a test may have taken away.
    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String, modified: Date? = nil) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    /// Copies `Fixtures/<path>` to `relativePath`.
    @discardableResult
    func copyFixture(_ path: String, to relativePath: String, modified: Date? = nil) throws -> URL {
        try write(fixtureText(path), to: relativePath, modified: modified)
    }
}

/// Creates `directory` and its parents at 0755, the way a dev probe created the support folder before it was owner-only.
func makeWorldReadableDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
}

func posixMode(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

func output(_ stdout: String = "", stderr: String = "", exitCode: Int32 = 0, timedOut: Bool = false) -> ProcessResult {
    ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
}

func output(stdout: Data, exitCode: Int32 = 0, timedOut: Bool = false) -> ProcessResult {
    ProcessResult(exitCode: exitCode, stdout: stdout, stderr: Data(), timedOut: timedOut)
}

/// Stands in for a CLI: records every run and answers it from `answers` in order, then from `respond`. Never spawns a process.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL?
        var stdin: Data?
        var timeout: TimeInterval
        var outputLimit: Int
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var queued: [ProcessResult] = []
    private let respond: @Sendable (Call) throws -> ProcessResult

    init(_ respond: @escaping @Sendable (Call) throws -> ProcessResult = { _ in output() }) { self.respond = respond }

    convenience init(_ result: ProcessResult) { self.init { _ in result } }

    var answers: [ProcessResult] {
        get { lock.withLock { queued } }
        set { lock.withLock { queued = newValue } }
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        let call = Call(
            executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, stdin: stdin,
            timeout: timeout, outputLimit: outputLimit
        )
        let next = lock.withLock {
            recorded.append(call)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        return try next ?? respond(call)
    }
}
