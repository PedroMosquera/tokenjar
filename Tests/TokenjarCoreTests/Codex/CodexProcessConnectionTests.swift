import Foundation
import Testing
@testable import TokenjarCore

/// Drives the real pipe plumbing with a tiny shell stand-in for `codex app-server`.
struct CodexProcessConnectionTests {
    private static let fakeServer = """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"initialize"'*) printf '{"method":"remoteControl/status/changed"}\\n{"id":1,'; printf '"result":{}}\\n' ;;
        *'"account/rateLimits/read"'*) printf '{"id":2,"result":{"rateLimits":null}}\\n' ;;
      esac
    done
    """

    private func launch(_ script: String, in temp: TemporaryDirectory) throws -> any CodexAppServerConnection {
        let file = try temp.write(script, to: "fake-app-server.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return try ProcessCodexAppServerLauncher().launch(
            executable: file, arguments: [], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: temp.url
        )
    }

    @Test func exchangesLinesWithARealProcess() async throws {
        let temp = TemporaryDirectory()
        let connection = try launch(Self.fakeServer, in: temp)
        defer { connection.terminate() }

        let line = try await CodexAppServerSession.readRateLimits(over: connection, clientVersion: "dev")

        #expect(String(decoding: line, as: UTF8.self) == #"{"id":2,"result":{"rateLimits":null}}"#)
    }

    @Test func terminateFinishesTheLineStream() async throws {
        let temp = TemporaryDirectory()
        let connection = try launch("#!/bin/sh\nwhile :; do sleep 1; done\n", in: temp)

        connection.terminate()
        connection.terminate()
        var iterator = connection.lines.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func sendingAfterTheServerExitedThrowsInsteadOfKillingTheApp() async throws {
        let temp = TemporaryDirectory()
        let connection = try launch("#!/bin/sh\nexit 0\n", in: temp)
        defer { connection.terminate() }
        var iterator = connection.lines.makeAsyncIterator()
        #expect(await iterator.next() == nil)

        #expect(throws: (any Error).self) {
            for _ in 0..<64 { try connection.send(Data(repeating: 0x20, count: 65_536)) }
        }
    }
}
