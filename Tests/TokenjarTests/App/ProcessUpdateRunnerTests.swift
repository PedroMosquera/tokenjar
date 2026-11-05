import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private nonisolated final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    var value: Int32? { lock.withLock { status } }
    func set(_ value: Int32) { lock.withLock { status = value } }
}

@MainActor
struct ProcessUpdateRunnerTests {
    private func log() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tokenjar-update-log-\(UUID().uuidString)")
        try Data("earlier line\n".utf8).write(to: url)
        return url
    }

    private func shell(_ script: String) -> UpdateStep {
        UpdateStep(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "SECRET_HOME": "/Users/me"])
    }

    @Test func aBuildAppendsItsCommandAndOutputAndReturnsItsStatus() async throws {
        let log = try log()
        defer { try? FileManager.default.removeItem(at: log) }
        let status = await ProcessUpdateRunner().build(shell("echo out; echo err >&2; exit 3"), log: log)
        #expect(status == 3)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text == "earlier line\n$ /bin/sh -c echo out; echo err >&2; exit 3\nout\nerr\n")
        #expect(!text.contains("/Users/me"))
    }

    @Test func aBuildThatCannotStartFails() async throws {
        let log = try log()
        defer { try? FileManager.default.removeItem(at: log) }
        let status = await ProcessUpdateRunner().build(UpdateStep(executable: "/nonexistent/tool", arguments: [], environment: [:]), log: log)
        #expect(status != 0)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("could not start /nonexistent/tool"))
    }

    @Test func anInstallReturnsAtOnceAndReportsItsExitLater() async throws {
        let log = try log()
        defer { try? FileManager.default.removeItem(at: log) }
        let box = ExitBox()
        let started = Date()
        try ProcessUpdateRunner().install(shell("sleep 2; echo done; exit 4"), log: log) { box.set($0) }
        #expect(Date().timeIntervalSince(started) < 1.5)
        try await waitUntil { box.value != nil }
        #expect(box.value == 4)
        #expect(try String(contentsOf: log, encoding: .utf8).hasSuffix("done\n"))
    }
}
