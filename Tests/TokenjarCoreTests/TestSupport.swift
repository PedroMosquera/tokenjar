import Foundation
@testable import TokenjarCore

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
