import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct QuitConfirmationTests {
    @Test func theFirstRequestAsks() {
        var confirmation = QuitConfirmation()
        let asks = confirmation.shouldAsk()
        #expect(asks)
    }

    /// Two quick clicks on Quit would otherwise queue a second alert behind the first.
    @Test func aRequestWhileTheAlertIsUpDoesNotAskAgain() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk()
        let asksAgain = confirmation.shouldAsk()
        #expect(!asksAgain)
    }

    @Test func quitQuitsAndCancelDoesNot() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk()
        let quitQuits = confirmation.quits(after: .alertFirstButtonReturn)
        _ = confirmation.shouldAsk()
        let cancelQuits = confirmation.quits(after: .alertSecondButtonReturn)
        #expect(quitQuits)
        #expect(!cancelQuits)
    }

    @Test func eitherAnswerLetsTheNextRequestAsk() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk()
        _ = confirmation.quits(after: .alertSecondButtonReturn)
        let asksAfterCancel = confirmation.shouldAsk()
        _ = confirmation.quits(after: .alertFirstButtonReturn)
        let asksAfterQuit = confirmation.shouldAsk()
        #expect(asksAfterCancel)
        #expect(asksAfterQuit)
    }

    /// Built only: running it would put an alert on screen.
    @Test func theAlertOffersQuitOnReturnAndCancelOnEscape() {
        let alert = QuitConfirmation.makeAlert()
        #expect(alert.alertStyle == .informational)
        #expect(alert.messageText == "Quit Tokenjar?")
        #expect(alert.informativeText == "Usage checks and alerts stop until you open Tokenjar again from Spotlight or Finder.")
        #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}"])
        #expect(!alert.showsSuppressionButton)
    }

    /// The popover's Quit button and its Command-Q call `quit`, and PopoverFooter does not know about the alert.
    @Test func thePopoversQuitAsksTheAppInsteadOfQuitting() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let model = AppModel(paths: home.paths, fetcher: { _ in FakeFetcher(log: FetchLog()) { .success(usageSnapshot($0)) } })
        var requests = 0
        model.presenter.requestQuit = { requests += 1 }

        model.quit()

        #expect(requests == 1)
    }
}
