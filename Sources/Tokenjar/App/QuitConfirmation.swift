import AppKit

/// Whether a quit request from Tokenjar's own controls asks first, what the answer does, and the alert it shows.
struct QuitConfirmation {
    enum Outcome: Equatable {
        case quit
        /// Cancel. `refocus` is the app that was in front when the request came, unless that was Tokenjar.
        case stay(refocus: NSRunningApplication?)
    }

    private(set) var isAsking = false
    private var appInFront: NSRunningApplication?

    /// False while the alert from an earlier request is still up, so two quick requests never stack two alerts.
    /// `frontmost` must be read before Tokenjar activates to show the alert.
    mutating func shouldAsk(frontmost: NSRunningApplication?) -> Bool {
        guard !isAsking else { return false }
        isAsking = true
        appInFront = frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : frontmost
        return true
    }

    /// Either answer lets the next request ask again.
    mutating func outcome(of response: NSApplication.ModalResponse) -> Outcome {
        defer { isAsking = false }
        return response == .alertFirstButtonReturn ? .quit : .stay(refocus: appInFront)
    }

    /// NSAlert gives Return to the first button and Escape to a button titled Cancel.
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Quit Tokenjar?"
        alert.informativeText = "Usage checks and alerts stop until you open Tokenjar again from Spotlight or Finder."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
