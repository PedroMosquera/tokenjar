#if os(Windows)
import Foundation
import Testing
@testable import TokenjarCore

/// Runs real Windows programs through `WindowsChildProcess`, the Windows side of `ProcessRunnerTests` and
/// `CodexProcessConnectionTests`. `.timeLimit` only backstops a hang; elapsed-time bounds are asserted with a clock.
@Suite(.timeLimit(.minutes(3)))
struct WindowsProcessTests {
    let runner = FoundationProcessRunner()
    private static let environment = ProcessInfo.processInfo.environment
    private static let system = URL(fileURLWithPath: environment["SystemRoot"] ?? #"C:\Windows"#).appending(path: "System32")
    private static let powershell = system.appending(path: "WindowsPowerShell/v1.0/powershell.exe")

    private func cmd(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await runner.run(
            Self.system.appending(path: "cmd.exe"), arguments: ["/d", "/c", command], environment: Self.environment,
            currentDirectory: nil, stdin: stdin, timeout: timeout, outputLimit: 1 << 20
        )
    }

    @Test func stdoutStderrAndTheExitCodeArriveApart() async throws {
        let result = try await cmd("echo out& echo err 1>&2& exit /b 3")
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\r\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err \r\n")
    }

    @Test func stdinReachesTheProgram() async throws {
        let result = try await runner.run(
            Self.system.appending(path: "sort.exe"), arguments: [], environment: Self.environment,
            currentDirectory: nil, stdin: Data("b\r\na\r\n".utf8), timeout: 30, outputLimit: 1024
        )
        #expect(String(decoding: result.stdout, as: UTF8.self) == "a\r\nb\r\n")
    }

    /// ping is cmd's child, so it outlives a stop of cmd alone and keeps stdout open for its 30 seconds. Only the job
    /// object ends both, which is what lets the run return at once.
    @Test func aTimeoutEndsTheProgramAndWhatItStarted() async throws {
        let clock = SuspendingClock()
        let start = clock.now
        let result = try await cmd("ping -n 30 127.0.0.1", timeout: 0.5)
        #expect(result.timedOut)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func aLaunchFailureThrows() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(
                URL(fileURLWithPath: #"C:\nonexistent\tokenjar-cli.exe"#), arguments: [], environment: Self.environment,
                currentDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024
            )
        }
    }

    /// The arguments reach node exactly as given, the JSON of `claude --settings` included, which cmd.exe would mangle.
    @Test(.enabled(if: nodeIsOnThePath)) func anNpmShimRunsItsScriptUnderNode() async throws {
        let temp = TemporaryDirectory()
        try temp.write(#"console.log(JSON.stringify(process.argv.slice(2)))"#, to: "node_modules/fake-cli/cli.js")
        let shim = try temp.write(Self.cmdShim(entry: #"node_modules\fake-cli\cli.js"#), to: "fake-cli.cmd")
        let arguments = ["--settings", #"{"disableAllHooks":true}"#, "two words", #"back\slash\"#, ""]

        let result = try await runner.run(
            shim, arguments: arguments, environment: Self.environment, currentDirectory: nil, stdin: nil, timeout: 30, outputLimit: 1 << 16
        )

        let echoed = try JSONDecoder().decode([String].self, from: result.stdout)
        #expect(echoed == arguments)
    }

    @Test func aCmdThatIsNotAnNpmShimIsRefused() async throws {
        let temp = TemporaryDirectory()
        let script = try temp.write("@echo hi\r\n", to: "other.cmd")
        await #expect(throws: WindowsProcessError.self) {
            try await runner.run(script, arguments: [], environment: Self.environment, currentDirectory: nil, stdin: nil, timeout: 5, outputLimit: 1024)
        }
    }

    // MARK: codex app-server

    private static let fakeServer = #"""
    $in = [Console]::In
    while (($line = $in.ReadLine()) -ne $null) {
      if ($line -like '*"initialize"*') {
        [Console]::Out.Write('{"method":"remoteControl/status/changed"}' + "`n" + '{"id":1,')
        [Console]::Out.Flush()
        [Console]::Out.Write('"result":{}}' + "`n")
      } elseif ($line -like '*"account/rateLimits/read"*') {
        [Console]::Out.Write('{"id":2,"result":{"rateLimits":null}}' + "`n")
      }
      [Console]::Out.Flush()
    }
    """#

    private func launchServer(_ script: String, in temp: TemporaryDirectory) throws -> any CodexAppServerConnection {
        let file = try temp.write(script, to: "fake-app-server.ps1")
        return try ProcessCodexAppServerLauncher().launch(
            executable: Self.powershell, arguments: ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", windowsPath(file)],
            environment: Self.environment, currentDirectory: temp.url
        )
    }

    @Test func exchangesLinesWithARealProcess() async throws {
        let temp = TemporaryDirectory()
        let connection = try launchServer(Self.fakeServer, in: temp)
        defer { connection.terminate() }

        let line = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")

        #expect(String(decoding: line, as: UTF8.self) == #"{"id":2,"result":{"rateLimits":null}}"#)
    }

    @Test func terminateFinishesTheLineStream() async throws {
        let temp = TemporaryDirectory()
        let connection = try launchServer("Start-Sleep -Seconds 60", in: temp)

        connection.terminate()
        connection.terminate()
        var iterator = connection.lines.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func sendingAfterTheServerExitedThrows() async throws {
        let temp = TemporaryDirectory()
        let connection = try launchServer("exit 0", in: temp)
        defer { connection.terminate() }
        var iterator = connection.lines.makeAsyncIterator()
        #expect(await iterator.next() == nil)

        #expect(throws: (any Error).self) {
            for _ in 0..<64 { try connection.send(Data(repeating: 0x20, count: 65_536)) }
        }
    }

    /// What npm's cmd-shim writes for a package's bin entry.
    static func cmdShim(entry: String) -> String {
        """
        @ECHO off\r
        GOTO start\r
        :find_dp0\r
        SET dp0=%~dp0\r
        EXIT /b\r
        :start\r
        SETLOCAL\r
        CALL :find_dp0\r
        \r
        IF EXIST "%dp0%\\node.exe" (\r
          SET "_prog=%dp0%\\node.exe"\r
        ) ELSE (\r
          SET "_prog=node"\r
          SET PATHEXT=%PATHEXT:;.JS;=;%\r
        )\r
        \r
        endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\\(entry)" %*\r

        """
    }
}

private let nodeIsOnThePath: Bool = {
    let path = ProcessInfo.processInfo.environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
    return path.split(separator: ";").contains { FileManager.default.fileExists(atPath: URL(fileURLWithPath: String($0)).appending(path: "node.exe").path) }
}()
#endif
