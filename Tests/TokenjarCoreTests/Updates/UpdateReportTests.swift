import Foundation
import Testing
@testable import TokenjarCore

struct UpdateReportTests {
    private let home = "/Users/jdoe"
    private let user = "jdoe"

    private func report(log: String, method: UpdateMethod = .releaseArchive) -> UpdateReport {
        UpdateReport(
            from: "0.3.0", to: AppVersion("0.4.0")!, method: method, macOS: "Version 26.0 (Build 25A354)",
            swift: "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)", log: log
        )
    }

    private func fields(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func opensTheUpdateFailureFormWithEveryFieldFilled() {
        let url = report(log: "one\ntwo\n").url(home: home, user: user)
        #expect(url.absoluteString.hasPrefix("https://github.com/PedroMosquera/tokenjar/issues/new?"))
        let values = fields(url)
        #expect(values["template"] == "update-failure.yml")
        #expect(values["title"] == "Update to 0.4.0 failed")
        #expect(values["from"] == "0.3.0")
        #expect(values["to"] == "0.4.0")
        #expect(values["method"] == "Release archive")
        #expect(values["macos"] == "Version 26.0 (Build 25A354)")
        #expect(values["swift"] == "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)")
        #expect(values["log"] == "one\ntwo")
        #expect(fields(report(log: "", method: .homebrew(prefix: "/opt/homebrew")).url(home: home, user: user))["method"] == "Homebrew")
    }

    @Test func onlyTheLastFortyLogLinesGoIn() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let sent = fields(report(log: log).url(home: home, user: user))["log"]?.components(separatedBy: "\n")
        #expect(sent == (61...100).map { "line \($0)" })
    }

    @Test func theHomeFolderAndUserNameNeverReachTheURL() {
        let log = """
        $ /bin/bash /Users/jdoe/Applications/Tokenjar.app/Contents/Resources/get.sh
        cp: /Users/jdoe/Library/Application Support/Tokenjar/update/install.sh: denied for jdoe
        owner jdoe:staff, see /Users/jdoe
        """
        let url = report(log: log).url(home: home, user: user)
        let decoded = fields(url).values.joined(separator: "\n")
        #expect(!decoded.contains("/Users/jdoe"))
        #expect(!decoded.contains("jdoe"))
        #expect(!url.absoluteString.contains("jdoe"))
        #expect(decoded.contains("~/Applications/Tokenjar.app/Contents/Resources/get.sh"))
        #expect(decoded.contains("~/Library/Application Support/Tokenjar/update/install.sh"))
    }

    /// Real login names carry dots and capitals that a made-up one does not.
    @Test func thisMacsOwnHomeAndUserNameAreRemoved() {
        let home = NSHomeDirectory(), user = NSUserName()
        let log = "cd \(home)/Library/Caches\nowner \(user):staff\nchown \(user.uppercased()) \(home)"
        let url = report(log: log).url(home: home, user: user)
        let decoded = fields(url).values.joined(separator: "\n")
        #expect(!decoded.localizedCaseInsensitiveContains(user))
        #expect(!decoded.contains(home))
        #expect(fields(url)["log"] == "cd ~/Library/Caches\nowner <user>:staff\nchown <user> ~")
    }

    @Test func everyFieldIsRedactedNotOnlyTheLog() {
        var leaky = report(log: "")
        leaky.swift = "Apple Swift 6.3 at /Users/jdoe/toolchains"
        leaky.macOS = "jdoe's Mac"
        let decoded = fields(leaky.url(home: home, user: user)).values.joined(separator: "\n")
        #expect(!decoded.contains("jdoe"))
    }

    @Test func aNameJoinedByPunctuationIsRemovedToo() {
        let text = "host jdoe-mbp.local and /private/tmp/jdoe-build and jdoe_cache and com.jdoe.x"
        #expect(UpdateReport.redact(text, home: home, user: user) == "host <user>-mbp.local and /private/tmp/<user>-build and <user>_cache and com.<user>.x")
    }

    @Test func thePerUserTemporaryFolderIdIsRemoved() {
        let text = "error: /private/var/folders/x7/abc123def_ghi/T/tokenjar-install.Ab12/src/Main.swift:3: oops"
        #expect(UpdateReport.redact(text, home: home, user: user) == "error: /private/var/folders/<id>/T/tokenjar-install.Ab12/src/Main.swift:3: oops")
    }

    @Test func aNameInsideAnotherWordIsKept() {
        #expect(UpdateReport.redact("make swiftbuild by ann; annex annie ann", home: "/Users/ann", user: "ann") == "make swiftbuild by <user>; annex annie <user>")
    }

    @Test func aRootOrEmptyHomeAndAOneLetterNameRedactNothing() {
        #expect(UpdateReport.redact("/usr/bin/a b", home: "/", user: "a") == "/usr/bin/a b")
        #expect(UpdateReport.redact("/usr/bin", home: "", user: "") == "/usr/bin")
    }

    @Test func theURLStaysUnder8000CharactersByDroppingTheOldestLines() {
        let long = String(repeating: "x", count: 400)
        let log = (1...40).map { "\($0) \(long)" }.joined(separator: "\n")
        let url = report(log: log).url(home: home, user: user)
        #expect(url.absoluteString.count < UpdateReport.maxURLLength)
        let sent = fields(url)["log"]?.components(separatedBy: "\n") ?? []
        #expect(!sent.isEmpty)
        #expect(sent.last == "40 \(long)")
        #expect(sent.first.map { !$0.hasPrefix("1 ") } ?? false)
    }

    @Test func aLastLineTooLongIsCutShortSoTheErrorStays() {
        let url = report(log: "line 1\nline 2\nerror: " + String(repeating: "z", count: 20_000)).url(home: home, user: user)
        #expect(url.absoluteString.count < UpdateReport.maxURLLength)
        #expect(url.absoluteString.count > UpdateReport.maxURLLength - 50)
        #expect(fields(url)["log"]?.hasPrefix("error: zzz") == true)
        #expect(fields(url)["to"] == "0.4.0")
    }

    @Test func longShortFieldsStillLeaveTheAddressUnderTheCap() {
        var long = report(log: "the error")
        long.swift = String(repeating: "\u{4E2D}", count: 4000)
        long.macOS = String(repeating: "m", count: 9000)
        let url = long.url(home: home, user: user)
        #expect(url.absoluteString.count < UpdateReport.maxURLLength)
        #expect(fields(url)["swift"]?.count == 200)
        #expect(fields(url)["log"] == "the error")
    }

    @Test func charactersThatMeanSomethingInAQueryArriveIntact() {
        let log = "a+b=c&d #e %f ?g"
        let url = report(log: log).url(home: home, user: user)
        #expect(fields(url)["log"] == log)
        // URLComponents reads a bare + back as +, but GitHub reads it as a space.
        #expect(url.absoluteString.contains("log=a%2Bb%3Dc%26d%20%23e%20%25f%20%3Fg"))
    }

    /// The form's field ids must match the URL's keys, or GitHub leaves those fields empty.
    @Test func theIssueFormDeclaresEveryFieldTheURLFills() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let form = try String(contentsOf: repo.appending(path: ".github/ISSUE_TEMPLATE/update-failure.yml"), encoding: .utf8)
        for id in UpdateReport.fieldIDs {
            #expect(form.contains("id: \(id)\n"), "missing id \(id)")
        }
        #expect(form.contains("labels: [update-failure]"))
        let config = try String(contentsOf: repo.appending(path: ".github/ISSUE_TEMPLATE/config.yml"), encoding: .utf8)
        #expect(config.contains("blank_issues_enabled: true"))
    }
}
