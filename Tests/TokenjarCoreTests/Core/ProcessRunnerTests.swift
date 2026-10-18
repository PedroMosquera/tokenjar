import Foundation
import Testing
@testable import TokenjarCore

// Shell scripts and /bin tools; Windows runs its own programs in WindowsProcessTests.
#if !os(Windows)

/// Runs real /bin tools. `.timeLimit` only backstops a hang; elapsed-time bounds are asserted with a clock.
/// A test can only lower it, not raise it, so it outlasts ten slow launches plus one 30 s process timeout.
@Suite(.timeLimit(.minutes(3)))
struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()

    /// The timeout only backstops a hang: launching a process can take seconds on a loaded Mac.
    private func run(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 30, outputLimit: Int = 1 << 20) async throws -> ProcessResult {
        try await runner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil, stdin: stdin, timeout: timeout, outputLimit: outputLimit
        )
    }

    /// The SIGTERM exit status is what proves the runner terminates before its SIGKILL backstop. The clock only catches a
    /// timeout that never fires, so its bound leaves room for a launch that takes seconds on a loaded Mac.
    @Test func timeoutTerminatesTheProcessPromptly() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let result = try await runner.run(
            URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
            currentDirectory: nil, stdin: nil, timeout: 0.3, outputLimit: 1024
        )
        #expect(result.timedOut)
        #expect(result.exitCode == SIGTERM)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func outputBeyondTheLimitIsDiscardedPerStream() async throws {
        let result = try await run("head -c 100000 /dev/zero; head -c 50000 /dev/zero >&2", outputLimit: 1_000)
        try #require(!result.timedOut)
        #expect(result.stdout.count == 1_000)
        #expect(result.stderr.count == 1_000)
    }

    /// Without F_SETNOSIGPIPE the write below raises SIGPIPE, which kills the whole test process (and the app).
    @Test func aCLIThatExitsBeforeReadingStdinDoesNotKillTheCaller() async throws {
        let result = try await run("exit 0", stdin: Data(count: 1 << 20))
        #expect(result.exitCode == 0)
    }

    @Test func aLaunchFailureThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(
                URL(fileURLWithPath: "/nonexistent/tokenjar-cli"), arguments: [], environment: [:],
                currentDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024
            )
        }
    }

    /// stream-json is parsed line by line, so a chunk appended out of order would split a line.
    @Test func largeOutputArrivesCompleteAndInOrder() async throws {
        let expected = Data((1...60_000).map { "line \($0)\n" }.joined().utf8)
        for _ in 0..<10 {
            // One process rather than a pipeline, so the test launches as little as it can.
            let result = try await runner.run(
                URL(fileURLWithPath: "/usr/bin/seq"), arguments: ["-f", "line %g", "1", "60000"], environment: [:],
                currentDirectory: nil, stdin: nil, timeout: 30, outputLimit: 1 << 20
            )
            try #require(!result.timedOut)
            let stdout = result.stdout
            // Not `#expect(stdout == expected)`: on failure Swift Testing diffs the two 600 KB collections, which never ends.
            let firstDifference = zip(stdout, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(stdout.count, expected.count)
            #expect(stdout.count == expected.count && firstDifference == expected.count, "\(stdout.count) bytes, first difference at \(firstDifference)")
        }
    }
}
#endif
