import Foundation
import Testing
@testable import TokenjarCore

/// docs/privacy.md is the contract for what Tokenjar runs. The command lines and variables checked here are recorded
/// from the fetchers and `CLILocator` themselves, so a new argument or variable fails until the page names it.
struct DocsPinTests {
    @Test func privacyNamesEveryCLICall() async throws {
        let commands = try Self.privacySection("## Commands it runs")
        let calls = try await Self.recordedCalls()
        #expect(calls.map(\.executable.lastPathComponent) == ["claude", "codex", "agy", "agy", "gh"])

        let passed = CLILocator.inheritedVariables + CLILocator.proxyVariables
        let everyInherited = Dictionary(uniqueKeysWithValues: passed.map { ($0, "set") })
        let environments = calls.map(\.environment) + [CLILocator().baseEnvironment(inherited: everyInherited)]
        let variables = Set(environments.flatMap { $0.map { "\($0.key)=\($0.value)" } })

        for call in calls {
            let line = Self.commandLine(call)
            #expect(commands.contains(line), "\(line)")
        }
        #expect(commands.contains(CopilotUsageFetcher.filter))
        for variable in variables.sorted() {
            let key = String(variable.prefix { $0 != "=" })
            #expect(commands.contains("`\(key)`") || commands.contains("`\(variable)`"), "\(key)")
        }
    }

    /// The page shows gh's jq program once in its own block and `<filter>` in the command line.
    private static func commandLine(_ call: Call) -> String {
        let words = call.arguments.map { $0 == CopilotUsageFetcher.filter ? "<filter>" : $0 }
        return ([call.executable.lastPathComponent] + words.map(shellQuoted)).joined(separator: " ")
    }

    private static func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_/.:".contains($0) } ? word : "'\(word)'"
    }

    private static func privacySection(_ heading: String) throws -> String {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/privacy.md")
        let lines = try String(contentsOf: doc, encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: heading), "docs/privacy.md has no \"\(heading)\" section")
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// Every account sets a profile folder, so the per-CLI variables that depend on one are recorded too.
    private static func recordedCalls() async throws -> [Call] {
        let home = FileManager.default.temporaryDirectory.appending(path: "tokenjar-docs-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        var overrides: [String: String] = [:]
        for cli in ["claude", "codex", "agy", "gh"] {
            let binary = home.appending(path: "bin/\(cli)")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            overrides[cli] = binary.path
        }
        // agy has to pass its version check for the `/usage` run to be recorded too.
        let agyVersion = output("agy " + AntigravityUsageFetcher.minimumVersion.map(String.init).joined(separator: "."))
        let runner = FakeRunner { $0.arguments == ["--version"] ? agyVersion : output(exitCode: 1) }
        let launcher = RecordingCodexLauncher(ScriptedCodexConnection(replies: [:], finishAfter: "initialize"))
        let context = FetchContext(
            process: runner, secrets: InMemorySecretStore(), cli: CLILocator(home: home, overrides: overrides, searchDirectories: []), paths: AppPaths(home: home)
        )
        func account(_ provider: ProviderID) -> AccountConfig {
            AccountConfig(id: provider.rawValue, provider: provider, label: "Docs", profileDir: "~/profile-\(provider.rawValue)")
        }

        _ = try? await ClaudeUsageFetcher().fetch(account(.claude), context: context)
        let claudeCount = runner.calls.count
        _ = try? await CodexUsageFetcher(launcher: launcher, timeout: 5).fetch(account(.codex), context: context)
        let codex = launcher.launches.map { Call(executable: $0.executable, arguments: $0.arguments, environment: $0.environment) }
        _ = try? await AntigravityUsageFetcher().fetch(account(.antigravity), context: context)
        _ = try? await CopilotUsageFetcher().fetch(account(.copilot), context: context)
        let recorded = runner.calls.map { Call(executable: $0.executable, arguments: $0.arguments, environment: $0.environment) }
        return recorded.prefix(claudeCount) + codex + recorded.dropFirst(claudeCount)
    }
}

private struct Call {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
}
