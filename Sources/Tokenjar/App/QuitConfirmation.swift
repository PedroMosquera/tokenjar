import AppKit

/// Whether a quit request asks first, and the alert it shows. The popover's Quit and its Command-Q, the status item
/// menu's "Quit Tokenjar..." and the app menu's Quit come here. Dock > Quit, AppleScript, logout, restart and the status
/// item menu's Option alternate call `terminate` directly, and the app implements no `applicationShouldTerminate`, so
/// none of them is ever held up.
struct QuitConfirmation {
    private(set) var isAsking = false

    /// False while the alert from an earlier request is still up, so two quick requests never stack two alerts.
    mutating func shouldAsk() -> Bool {
        defer { isAsking = true }
        return !isAsking
    }

    /// Whether the answer quits. Either answer lets the next request ask again.
    mutating func quits(after response: NSApplication.ModalResponse) -> Bool {
        isAsking = false
        return response == .alertFirstButtonReturn
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
