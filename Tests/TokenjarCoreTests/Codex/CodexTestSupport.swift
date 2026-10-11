import Foundation
@testable import TokenjarCore

enum CodexFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/Codex")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func line(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func lines(_ name: String) throws -> [String] {
        String(decoding: try data(name), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func rateLimitsResult(_ name: String) throws -> CodexRateLimitsResult {
        struct Envelope: Decodable { var result: CodexRateLimitsResult }
        return try JSONDecoder().decode(Envelope.self, from: data(name)).result
    }
}

/// A scratch directory that stands in for a home folder or CODEX_HOME. Removed when the value is released.
final class CodexTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "headroom-codex-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ contents: String, to relativePath: String, modified: Date? = nil) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    @discardableResult
    func copyFixture(_ name: String, to relativePath: String, modified: Date? = nil) throws -> URL {
        try write(String(decoding: CodexFixtures.data(name), as: UTF8.self), to: relativePath, modified: modified)
    }

    /// An executable placeholder the CLI locator accepts. It is never run: tests inject a fake launcher.
    func fakeCodexBinary() throws -> URL {
        let file = try write("#!/bin/sh\nexit 1\n", to: "bin/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}

/// Plays the server side of `codex app-server`: each request method gets canned reply lines.
final class ScriptedCodexConnection: CodexAppServerConnection, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let replies: [String: [String]]
    private let finishAfter: String?
    private let lock = NSLock()
    private var sentData: [Data] = []
    private var terminateCount = 0

    init(replies: [String: [String]], finishAfter method: String? = nil) {
        (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        self.replies = replies
        self.finishAfter = method
    }

    func send(_ message: Data) throws {
        lock.withLock { sentData.append(message) }
        let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
        guard let method = object?["method"] as? String else { return }
        for line in replies[method] ?? [] { continuation.yield(Data(line.utf8)) }
        if method == finishAfter { continuation.finish() }
    }

    func terminate() {
        lock.withLock { terminateCount += 1 }
        continuation.finish()
    }

    var sent: [Data] { lock.withLock { sentData } }
    var terminated: Bool { lock.withLock { terminateCount > 0 } }

    var sentObjects: [[String: Any]] {
        sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var sentMethods: [String] { sentObjects.compactMap { $0["method"] as? String } }

    static func answering(rateLimits line: String) -> ScriptedCodexConnection {
        ScriptedCodexConnection(replies: [
            "initialize": [#"{"id":1,"result":{"userAgent":"placeholder"}}"#],
            CodexAppServerSession.rateLimitsMethod: [line],
        ])
    }
}

final class RecordingCodexLauncher: CodexAppServerLaunching, @unchecked Sendable {
    struct Launch {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL
    }

    let connection: ScriptedCodexConnection
    private let lock = NSLock()
    private var recorded: [Launch] = []

    init(_ connection: ScriptedCodexConnection) { self.connection = connection }

    func launch(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL) throws -> any CodexAppServerConnection {
        lock.withLock { recorded.append(Launch(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)) }
        return connection
    }

    var launches: [Launch] { lock.withLock { recorded } }
}

extension Date {
    static func codexFixture(_ iso: String) -> Date { DateParsing.iso8601(iso)! }
}
