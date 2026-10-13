import AppKit
import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private let now = Date(timeIntervalSince1970: 1_791_660_000)

private func snapshot(_ account: AccountConfig, windows: [String] = [], ago: TimeInterval = 60, notes: [String] = []) -> UsageSnapshot {
    UsageSnapshot(
        accountID: account.id, provider: account.provider,
        windows: windows.enumerated().map { UsageWindow(id: "w\($0.offset)", label: $0.element, usedPercent: 10, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)) },
        fetchedAt: now.addingTimeInterval(-ago), source: "test source", notes: notes
    )
}

/// Format owns how an age reads ("6m ago"); these tests pin where it goes.
private func age(_ seconds: TimeInterval) -> String {
    Format.age(of: now.addingTimeInterval(-seconds), now: now)
}

@MainActor
struct AccountStatusTextTests {
    private let claude = AccountConfig(id: "claude-work", provider: .claude, label: "Work", profileDir: "~/.claude-work")
    private let codex = AccountConfig(id: "codex", provider: .codex, label: "Plus")
    private let go = AccountConfig(id: "opencode-go", provider: .opencodeGo, label: "Go")
    private let zen = AccountConfig(id: "opencode-zen", provider: .opencodeZen, label: "Zen")
    private let devin = AccountConfig(id: "devin", provider: .devin, label: "Devin")

    private func text(_ account: AccountConfig, _ status: AccountStatus, missingPath: String? = nil, connectivity: Connectivity = .online) -> AccountStatusText {
        AccountStatusText.make(account: account, status: status, missingPath: missingPath, now: now, connectivity: connectivity)
    }

    @Test func offlineStatusSaysTheMacIsOffline() {
        let old = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"], ago: 25 * 60), error: .network("offline")), connectivity: .offline)
        #expect(old.symbol == "wifi.slash")
        #expect(old.tone == .neutral)
        #expect(old.text == "This Mac is offline. Tokenjar checks this account again when it is back online.")
        #expect(old.detail == "Showing data from \(age(25 * 60)).")
        #expect(old.caption == nil)
        let never = text(claude, AccountStatus(), connectivity: .offline)
        #expect(never.text == old.text)
        #expect(never.detail == nil)
        // Zen reads a local database, and a failure the user can fix is still the account's own.
        #expect(text(zen, AccountStatus(snapshot: snapshot(zen)), connectivity: .offline).text.hasPrefix("Local spend only"))
        #expect(text(codex, AccountStatus(error: .notSignedIn), connectivity: .offline).text == "Signed out of codex.")
        #expect(text(claude, AccountStatus(isRefreshing: true), connectivity: .offline).text == "Checking\u{2026}")
    }

    @Test func signedOutClaudeSaysWhereAShellOnlyLoginMustGo() {
        let line = text(claude, AccountStatus(error: .notSignedIn))
        #expect(line.text == "Signed out of claude.")
        #expect(line.detail == ClaudeUsageFetcher.shellOnlyLoginHint)
        #expect(FetchError.notSignedIn.userMessage(provider: .claude) == "Signed out of claude. Sign in again. \(ClaudeUsageFetcher.shellOnlyLoginHint)")
        #expect(text(codex, AccountStatus(error: .notSignedIn)).detail == nil)
    }

    @Test func noAnswerStatusSaysSo() {
        let line = text(codex, AccountStatus(snapshot: snapshot(codex, windows: ["Week"], ago: 3 * 3_600), error: .timeout), connectivity: .noAnswer)
        #expect(line.symbol == "wifi.exclamationmark")
        #expect(line.text == "Can't reach any provider. Tokenjar tries again at the next refresh.")
        #expect(line.detail == "Showing data from \(age(3 * 3_600)).")
        // Codex's logged copy stands in for a failed check without an error, and must not read as a fresh update.
        var logged = snapshot(codex, windows: ["Week"], ago: 2 * 86_400)
        logged.liveCheckFailure = .network
        let saved = text(codex, AccountStatus(snapshot: logged, lastAttempt: now), connectivity: .noAnswer)
        #expect(saved.text == line.text)
        #expect(saved.detail == "Showing data from \(age(2 * 86_400)).")
    }

    /// The same failure gets the card's icon, and a saved copy shown because of one says so rather than "Updated".
    @Test func aTransientFailureNamesTheProvider() {
        let reach = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"], ago: 50 * 60), error: .network("offline")))
        #expect(reach.text == "Can't reach Claude. Tokenjar tries again at the next refresh.")
        #expect(reach.symbol == "wifi.exclamationmark")
        let late = text(codex, AccountStatus(error: .timeout))
        #expect(late.text == "No answer from Codex in time. Tokenjar tries again at the next refresh.")
        #expect(late.symbol == "clock.arrow.circlepath")
        var cached = snapshot(claude, windows: ["5-hour"], ago: 3 * 3_600)
        cached.liveCheckFailure = .timeout
        let saved = text(claude, AccountStatus(snapshot: cached, lastAttempt: now))
        #expect(saved.text == "No answer from Claude in time. Tokenjar tries again at the next refresh.")
        #expect(saved.detail == "Showing data from \(age(3 * 3_600)).")
    }

    /// Offline, every account that needs the network is held, so one whose last check passed is not current either.
    @Test func aHeldAccountWithDataSaysTheCauseToo() {
        let passed = AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"], ago: 25 * 60), lastAttempt: now.addingTimeInterval(-25 * 60))
        let offline = text(claude, passed, connectivity: .offline)
        #expect(offline.symbol == "wifi.slash")
        #expect(offline.text == "This Mac is offline. Tokenjar checks this account again when it is back online.")
        #expect(offline.detail == "Showing data from \(age(25 * 60)).")
        #expect(text(claude, passed, connectivity: .noAnswer).text == "Can't reach any provider. Tokenjar tries again at the next refresh.")
        // A copy saved because the CLI is missing is the account's own problem, whatever the network does.
        var missing = snapshot(claude, windows: ["5-hour"], ago: 25 * 60)
        missing.liveCheckFailure = .other
        #expect(text(claude, AccountStatus(snapshot: missing, lastAttempt: now), connectivity: .offline).symbol != "wifi.slash")
    }

    @Test func noSubscriptionIsCalmNotAWarning() {
        let line = text(go, AccountStatus(error: .noSubscription("No active OpenCode Go subscription for this key")))
        #expect(line.symbol == "minus.circle")
        #expect(line.tone == .neutral)
        #expect(line.text == "Not subscribed to OpenCode Go")
        #expect(line.caption == AccountStatusText.Caption(text: "Not subscribed", isActionable: false))
    }

    @Test func anAccountMissingFromThisMacNamesThePathBeforeAnyOldSnapshot() {
        let line = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"])), missingPath: "~/.claude-work")
        #expect(line.symbol == "questionmark.folder")
        #expect(line.tone == .neutral)
        #expect(line.text == "Not on this Mac: ~/.claude-work does not exist")
        #expect(line.caption == AccountStatusText.Caption(text: "Not on this Mac", isActionable: false))
    }

    /// Zen has neither a profile folder nor a credential it reads, so Test's tooltip names the file that is missing.
    @Test func testIsBlockedByTheFileThatIsMissing() {
        #expect(AccountDetailView.testBlocker(enabled: true, missingPath: nil) == nil)
        #expect(AccountDetailView.testBlocker(enabled: false, missingPath: "~/.claude-work") == "Turn the account on to test it")
        #expect(
            AccountDetailView.testBlocker(enabled: true, missingPath: "~/.local/share/opencode/opencode.db")
                == "~/.local/share/opencode/opencode.db is not on this Mac"
        )
    }

    @Test func aSnapshotListsItsLimitsNotACount() {
        let line = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour", "Week", "Week \u{00B7} Fable"])))
        #expect(line.text == "Updated \(age(60))")
        #expect(line.detail.map(Self.readable) == "Limits: 5-hour, Week, Week \u{00B7} Fable")
        #expect(line.symbol == "checkmark.circle.fill")
        #expect(line.tone == .good)
        #expect(line.caption == nil)
    }

    /// "Gemini" at the end of one line and "· Week" at the start of the next reads as two windows. "two-day" stands
    /// for an agy window Tokenjar does not recognize, which keeps its raw name and can break after its hyphen.
    @Test func theLimitsListWrapsOnlyBetweenLabels() throws {
        let agy = AccountConfig(id: "antigravity", provider: .antigravity, label: "Google")
        let labels = ["Gemini \u{00B7} 5-hour", "Gemini \u{00B7} Week", "Claude and GPT \u{00B7} Week", "Gemini 3 Pro \u{00B7} Week", "Gemini \u{00B7} two-day"]
        let detail = try #require(text(agy, AccountStatus(snapshot: snapshot(agy, windows: labels))).detail)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let labelStarts = Set((["Limits:"] + labels).map { String($0.prefix(4)) })
        for width in stride(from: (widest + 12).rounded(.up), through: 420, by: 3) {
            for line in Self.lines(of: detail, font: font, width: width) {
                #expect(labelStarts.contains(String(Self.readable(line).prefix(4))), "line \"\(Self.readable(line))\" at width \(width)")
            }
        }
    }

    /// The list as it reads, whatever characters keep a label on one line.
    private static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
    }

    /// How TextKit wraps `text` at `width`, one string per line with its trailing space dropped.
    private static func lines(of text: String, font: NSFont, width: CGFloat) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines: [String] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append((text as NSString).substring(with: characters).trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    @Test func aSnapshotWithNoLimitsShowsItsNoteUnderTheAge() {
        let line = text(codex, AccountStatus(snapshot: snapshot(codex, notes: ["No usage limits reported for this account"])))
        #expect(line.text == "Updated \(age(60))")
        #expect(line.detail == "No usage limits reported for this account")
    }

    @Test func zenReportsLocalSpendNeverZeroWindows() {
        let line = text(zen, AccountStatus(snapshot: snapshot(zen, ago: 6 * 60)))
        #expect(line.text == "Local spend only \u{00B7} updated \(age(6 * 60))")
        #expect(!line.text.contains("window"))
    }

    @Test func aTransientErrorKeepsTheLastDataAndSaysHowOld() {
        let line = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"], ago: 50 * 60), error: .network("offline")))
        #expect(line.text == FetchError.network("offline").userMessage(provider: .claude))
        #expect(line.detail == "Showing data from \(age(50 * 60)).")
        #expect(line.tone == .neutral)
        #expect(line.caption == nil)
    }

    @Test func signedOutNamesTheCLI() {
        let line = text(codex, AccountStatus(error: .notSignedIn))
        #expect(line.text == "Signed out of codex.")
        #expect(line.tone == .warning)
        #expect(line.caption == AccountStatusText.Caption(text: "Signed out", isActionable: true))
    }

    @Test func aDeniedKeychainReadSaysSoAndThatNothingAsksAgain() {
        let pasted = AccountConfig(id: "go", provider: .opencodeGo, label: "Go", credential: .keychain(account: "go"))
        let line = text(pasted, AccountStatus(error: .keychainDenied))
        #expect(line.text == "Keychain access was denied. Tokenjar won't ask again on its own.")
        #expect(line.tone == .warning)
        #expect(line.caption == AccountStatusText.Caption(text: "Keychain denied", isActionable: true))
    }

    @Test func actionableCaptionsSayWhatToFix() {
        #expect(text(go, AccountStatus(error: .unauthorized)).caption == AccountStatusText.Caption(text: "Key rejected", isActionable: true))
        let latched = FetchError.unsupported(ClaudeUsageFetcher.modelTurnMessage)
        #expect(text(claude, AccountStatus(error: latched)).caption == AccountStatusText.Caption(text: "Paused", isActionable: true))
        #expect(text(claude, AccountStatus(error: .timeout)).caption == nil)
        #expect(text(codex, AccountStatus(error: .notSignedIn), missingPath: nil).caption?.isActionable == true)
    }

    @Test func aLinkOnlyAccountOpensItsPageAndHasNothingToCheck() {
        let line = text(devin, AccountStatus(snapshot: snapshot(devin)))
        #expect(line.symbol == "link")
        #expect(line.text == "Opens app.devin.ai")
        #expect(!line.offersCheck)
        #expect(line.tone == .neutral)
    }

    @Test func anAccountThatIsOffSaysSoEvenWithOldData() {
        var off = codex
        off.enabled = false
        let line = text(off, AccountStatus(snapshot: snapshot(off, windows: ["5-hour"])))
        #expect(line.text == "Off")
        #expect(line.caption == AccountStatusText.Caption(text: "Off", isActionable: false))
    }
}
