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

    private func text(_ account: AccountConfig, _ status: AccountStatus, missingPath: String? = nil) -> AccountStatusText {
        AccountStatusText.make(account: account, status: status, missingPath: missingPath, now: now)
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

    @Test func aSnapshotListsItsLimitsNotACount() {
        let line = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour", "Week", "Week \u{00B7} Fable"])))
        #expect(line.text == "Updated \(age(60)) \u{00B7} 5-hour, Week, Week \u{00B7} Fable")
        #expect(line.symbol == "checkmark.circle.fill")
        #expect(line.tone == .good)
        #expect(line.caption == nil)
    }

    @Test func zenReportsLocalSpendNeverZeroWindows() {
        let line = text(zen, AccountStatus(snapshot: snapshot(zen, ago: 6 * 60)))
        #expect(line.text == "Local spend only \u{00B7} updated \(age(6 * 60))")
        #expect(!line.text.contains("window"))
    }

    @Test func aTransientErrorKeepsTheLastDataAndSaysHowOld() {
        let line = text(claude, AccountStatus(snapshot: snapshot(claude, windows: ["5-hour"], ago: 50 * 60), error: .network("offline")))
        #expect(line.text == FetchError.network("offline").userMessage)
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
