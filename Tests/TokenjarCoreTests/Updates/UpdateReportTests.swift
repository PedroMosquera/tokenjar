import Foundation
import Testing
@testable import TokenjarCore

struct UpdateReportTests {
    private let home = "/Users/jdoe"
    private let user = "jdoe"

    private func report(log: String, method: UpdateMethod = .releaseArchive) -> UpdateReport {
        UpdateReport(
            from: "0.3.0", to: AppVersion("0.4.0")!, method: method, macOS: "Version 26.0 (Build 25A354)",
            swift: "swift-driver version: 1.148.6 Apple Swift version 6.3.2", log: log
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
        #expect(values["swift"] == "swift-driver version: 1.148.6 Apple Swift version 6.3.2")
        #expect(values["log"] == "one\ntwo")
        #expect(fields(report(log: "", method: .homebrew(prefix: "/opt/homebrew")).url(home: home, user: user))["method"] == "Homebrew")
    }

    @Test func onlyTheLastFortyLogLinesGoIn() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let sent = fields(report(log: log).url(home: home, user: user))["log"]?.components(separatedBy: "\n")
        #expect(sent == (61...100).map { "line \($0)" })
    }

    /// C-8.
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

    @Test func aNameInsideAnotherWordIsKept() {
        #expect(UpdateReport.redact("make swiftbuild by ann; annex annie ann", home: "/Users/ann", user: "ann") == "make swiftbuild by <user>; annex annie <user>")
    }

    @Test func aRootOrEmptyHomeAndAOneLetterNameRedactNothing() {
        #expect(UpdateReport.redact("/usr/bin/a b", home: "/", user: "a") == "/usr/bin/a b")
        #expect(UpdateReport.redact("/usr/bin", home: "", user: "") == "/usr/bin")
    }

    /// C-8.
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

    @Test func aSingleHugeLineStillFits() {
        let url = report(log: String(repeating: "y", count: 20_000)).url(home: home, user: user)
        #expect(url.absoluteString.count < UpdateReport.maxURLLength)
        #expect(fields(url)["to"] == "0.4.0")
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
