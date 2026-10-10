import Foundation
import Testing
@testable import HeadroomCore

struct SignInCommandTests {
    let paths = AppPaths(home: URL(fileURLWithPath: "/Users/tester"))

    private func command(_ account: AccountConfig, executable: (String) -> String = { $0 }) -> String? {
        SignInCommand.command(for: account, paths: paths, executable: executable)
    }

    @Test func claudeWithDefaultProfileSetsNoVariable() {
        #expect(command(AccountConfig(id: "claude", provider: .claude, label: "Personal")) == "claude auth login")
    }

    @Test func claudeProfileIsExpandedThenQuoted() {
        let account = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/Claude's work")
        #expect(command(account) == #"CLAUDE_CONFIG_DIR='/Users/tester/Claude'\''s work' claude auth login"#)
    }

    @Test func codexProfileUsesCodexHome() {
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus", profileDir: "~/.codex-work")
        #expect(command(account) == "CODEX_HOME=/Users/tester/.codex-work codex login")
    }

    @Test func blankProfileCountsAsDefault() {
        let account = AccountConfig(id: "codex", provider: .codex, label: "Plus", profileDir: "   ")
        #expect(command(account) == "codex login")
    }

    @Test(arguments: [ProviderID.opencodeGo, .opencodeZen])
    func openCodeIgnoresProfileDir(provider: ProviderID) {
        let account = AccountConfig(id: "oc", provider: provider, label: "Go", profileDir: "~/elsewhere")
        #expect(command(account) == "opencode auth login")
    }

    @Test func antigravityHasNoLoginCommand() {
        #expect(command(AccountConfig(id: "agy", provider: .antigravity, label: "Google")) == nil)
    }

    @Test func locatedExecutableWithSpacesIsQuoted() {
        let account = AccountConfig(id: "claude", provider: .claude, label: "Personal")
        #expect(command(account) { "/Applications/My Tools/\($0)" } == "'/Applications/My Tools/claude' auth login")
    }

    @Test(arguments: ["plain", "with space", "it's", "$(echo injected)", "`echo injected`", "a\"b", #"back\slash"#, "new\nline", "*", "~", "", "; echo injected"])
    func quotedWordReachesTheShellUnchanged(word: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + SignInCommand.shellQuote(word)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let printed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(printed == word)
    }

    @Test func safeWordsStayBare() {
        #expect(SignInCommand.shellQuote("/Users/tester/.claude-work") == "/Users/tester/.claude-work")
    }

    @Test func scriptFileNameCannotLeaveTheTemporaryFolder() {
        #expect(SignInCommand.scriptFileName(accountID: "../../Library/evil") == "headroom-sign-in-Libraryevil.command")
        #expect(SignInCommand.scriptFileName(accountID: "claude-work") == "headroom-sign-in-claude-work.command")
        #expect(SignInCommand.scriptFileName(accountID: "/") == "headroom-sign-in-account.command")
    }

    @Test func scriptRemovesItselfBeforeRunningTheCommand() throws {
        let script = SignInCommand.script(command: "codex login", title: "it's codex")
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == "#!/bin/sh")
        let remove = try #require(lines.firstIndex(of: #"rm -f "$0""#))
        let run = try #require(lines.firstIndex(of: "codex login"))
        #expect(remove < run)
        #expect(lines.contains(#"echo 'Headroom: it'\''s codex'"#))
    }
}
