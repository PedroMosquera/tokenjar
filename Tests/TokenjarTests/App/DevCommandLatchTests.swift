import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

/// The app latches an account whose probe ran as a model turn. A dev flag must not repeat that turn behind its back, so
/// `--capture` and `--probe` read the latch file the app writes and refuse that CLI's binary.
struct DevCommandLatchTests {
    @Test func captureRefusesALatchedCLI() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = try home.makeExecutable("bin/claude")
        try writeLatch(in: home, account: "work", cli: .claude, binary: ProbeLatch.fingerprint(ofBinaryAt: claude))
        let run = DevRun(home)

        let status = await DevCommands.run(["Tokenjar", "--capture", "claude"], in: run.environment)

        #expect(status == 1)
        #expect(run.cli.calls.isEmpty)
        #expect(run.output.isEmpty)
        #expect(run.errors.joined().contains("Try Once More"))
    }

    @Test func probeRefusesALatchedCLI() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let agy = try home.makeExecutable("bin/agy")
        try writeLatch(in: home, account: "google", cli: .agy, binary: ProbeLatch.fingerprint(ofBinaryAt: agy))
        let run = DevRun(home)

        let status = await DevCommands.run(["Tokenjar", "--probe", "antigravity"], in: run.environment)

        #expect(status == 1)
        #expect(run.cli.calls.isEmpty)
        #expect(run.errors.joined().contains("Try Once More"))
    }

    /// The app itself lets one run through on a new build, so the dev flags do too.
    @Test func anUpdatedBinaryIsNotBlocked() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let claude = try home.makeExecutable("bin/claude")
        try writeLatch(in: home, account: "work", cli: .claude, binary: ProbeLatch.fingerprint(ofBinaryAt: claude))
        try home.makeExecutable("bin/claude", contents: "#!/bin/sh\n# 2.2\nexit 1\n")
        let run = DevRun(home)

        let status = await DevCommands.run(["Tokenjar", "--capture", "claude"], in: run.environment)

        #expect(status == 0)
        #expect(run.cli.calls == [["-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#]])
        #expect(run.output.joined().contains(#""capture" : "claude""#))
    }

    /// A latch file the dev flag cannot read might hold a latch, so it refuses rather than guess.
    @Test func anUnreadableLatchFileRefuses() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeExecutable("bin/claude")
        try home.write("Library/Application Support/Tokenjar/probe-latch.json", "{not json")
        let run = DevRun(home)

        let status = await DevCommands.run(["Tokenjar", "--capture", "claude"], in: run.environment)

        #expect(status == 1)
        #expect(run.cli.calls.isEmpty)
    }

    @Test func aStoppedCaptureExitsWithAnError() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.makeExecutable("bin/agy")
        let run = DevRun(home, answer: "agy 1.1.10\n")

        let status = await DevCommands.run(["Tokenjar", "--capture", "antigravity"], in: run.environment)

        #expect(status == 1)
        #expect(run.output.isEmpty)
        #expect(run.errors.joined().contains("1.1.11"))
    }

    @Test func anUnknownProviderExitsWithAnError() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        let run = DevRun(home)

        for flag in ["--capture", "--probe"] {
            #expect(await DevCommands.run(["Tokenjar", flag, "claud"], in: run.environment) == 1, "\(flag)")
        }
        #expect(run.cli.calls.isEmpty)
    }

    /// The literal name, so a rename of `ProbeLatch.fileName` away from what the app writes fails here.
    private func writeLatch(in home: ModelHome, account: String, cli: ProbeLatch.CLI, binary: String?) throws {
        var latch = ProbeLatch()
        latch.latch(account, cli: cli, binary: binary)
        try home.write("Library/Application Support/Tokenjar/probe-latch.json", String(decoding: try JSONEncoder().encode(latch), as: UTF8.self))
    }
}

/// One dev command run against `home`: CLIs found only under `home/bin`, nothing spawned, output kept.
private final class DevRun {
    let cli: FakeCLI
    private(set) var output: [String] = []
    private(set) var errors: [String] = []
    private let home: ModelHome

    init(_ home: ModelHome, answer: String = #"{"type":"result","num_turns":0,"local_command":"usage","is_error":false}"#) {
        self.home = home
        cli = FakeCLI(stdout: answer)
    }

    var environment: DevCommands.Environment {
        var environment = DevCommands.Environment()
        environment.paths = AppPaths(home: home.url, environment: [:], systemRoot: home.url.appending(path: "root"))
        let bin = home.url.appending(path: "bin")
        environment.cli = CLILocator(home: home.url, overrides: ["claude": bin.appending(path: "claude").path, "agy": bin.appending(path: "agy").path])
        environment.process = cli
        environment.secrets = InMemorySecretStore()
        environment.output = { [unowned self] in output.append($0) }
        environment.errorOutput = { [unowned self] in errors.append($0) }
        return environment
    }
}

/// Answers every run with `stdout` and records the arguments. Never spawns a process.
private nonisolated final class FakeCLI: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let stdout: String

    init(stdout: String) { self.stdout = stdout }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        lock.withLock { recorded.append(arguments) }
        return ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(), timedOut: false)
    }
}
