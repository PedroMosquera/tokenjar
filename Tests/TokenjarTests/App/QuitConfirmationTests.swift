import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct QuitConfirmationTests {
    private let tokenjar = NSRunningApplication.current

    /// Any running app but the test runner, standing in for the app the person was typing in. Only read, never activated.
    private func otherApp() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != tokenjar.processIdentifier })
    }

    @Test func theFirstRequestAsks() {
        var confirmation = QuitConfirmation()
        let asks = confirmation.shouldAsk(frontmost: nil)
        #expect(asks)
    }

    /// Two quick clicks on Quit would otherwise queue a second alert behind the first.
    @Test func aRequestWhileTheAlertIsUpDoesNotAskAgain() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: nil)
        let asksAgain = confirmation.shouldAsk(frontmost: nil)
        #expect(!asksAgain)
    }

    @Test func quitQuitsAndCancelDoesNot() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: nil)
        let afterQuit = confirmation.outcome(of: .alertFirstButtonReturn)
        _ = confirmation.shouldAsk(frontmost: nil)
        let afterCancel = confirmation.outcome(of: .alertSecondButtonReturn)
        #expect(afterQuit == .quit)
        #expect(afterCancel == .stay(refocus: nil))
    }

    @Test func eitherAnswerLetsTheNextRequestAsk() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: nil)
        _ = confirmation.outcome(of: .alertSecondButtonReturn)
        let asksAfterCancel = confirmation.shouldAsk(frontmost: nil)
        _ = confirmation.outcome(of: .alertFirstButtonReturn)
        let asksAfterQuit = confirmation.shouldAsk(frontmost: nil)
        #expect(asksAfterCancel)
        #expect(asksAfterQuit)
    }

    /// The menu is the misclick case: Tokenjar activates only to show the alert, so after Cancel typing would go
    /// nowhere until the person clicked back into their app.
    @Test func cancelHandsFocusBackToTheAppThatWasInFront() throws {
        let other = try otherApp()
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: other)
        let outcome = confirmation.outcome(of: .alertSecondButtonReturn)
        #expect(outcome == .stay(refocus: other))
    }

    /// Command-Q in the Dashboard: the person was already in Tokenjar, so Cancel leaves them there.
    @Test func cancelLeavesFocusAloneWhenTokenjarWasInFront() {
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: tokenjar)
        let outcome = confirmation.outcome(of: .alertSecondButtonReturn)
        #expect(outcome == .stay(refocus: nil))
    }

    /// The app in front belongs to the request that asked, not to one dropped while its alert was up.
    @Test func eachRequestRemembersItsOwnApp() throws {
        let other = try otherApp()
        var confirmation = QuitConfirmation()
        _ = confirmation.shouldAsk(frontmost: other)
        _ = confirmation.shouldAsk(frontmost: tokenjar)
        let first = confirmation.outcome(of: .alertSecondButtonReturn)
        _ = confirmation.shouldAsk(frontmost: tokenjar)
        let second = confirmation.outcome(of: .alertSecondButtonReturn)
        #expect(first == .stay(refocus: other))
        #expect(second == .stay(refocus: nil))
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
        let refusal = RefusesToQuit()

        refusal.whileInstalled { model.quit() }

        #expect(!refusal.wasAsked)
        #expect(requests == 1)
    }

    /// Logout, restart and Dock > Quit go straight to terminate and never see the alert. An
    /// `applicationShouldTerminate` would sit in their path, where a mistake could hold up a logout.
    @Test func theAppLeavesQuitsItDidNotStartToAppKit() {
        #expect(!AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))))
    }
}

/// Stands in as the app's delegate while a test runs code that must not quit. A terminate call then asks this
/// delegate, which refuses, so the test fails on `wasAsked` instead of ending the test run with exit code 0.
final class RefusesToQuit: NSObject, NSApplicationDelegate {
    private(set) var wasAsked = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        wasAsked = true
        return .terminateCancel
    }

    func whileInstalled(_ body: () -> Void) {
        let app = NSApplication.shared
        let previous = app.delegate
        app.delegate = self
        defer { app.delegate = previous }
        body()
    }
}
