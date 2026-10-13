import AppKit

/// Who has the keyboard around the popover. Tokenjar activates to open it, so the popover's window is key: without
/// that, a transient popover never sees a click outside it and stays open, and its shortcuts get no keys.
struct PopoverFocus {
    /// The app that was in front when the popover opened, unless that was Tokenjar.
    private(set) var appBefore: NSRunningApplication?

    /// `frontmost` must be read before Tokenjar activates.
    mutating func opening(frontmost: NSRunningApplication?) {
        appBefore = frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : frontmost
    }

    /// The app to give the keyboard back to as the popover closes, or nil to leave it: after a click into another app,
    /// that app already has it, and a Tokenjar window or the quit alert opened from the popover needs Tokenjar in front.
    mutating func closing(tokenjarIsActive: Bool, keepsFocus: Bool) -> NSRunningApplication? {
        defer { appBefore = nil }
        return tokenjarIsActive && !keepsFocus ? appBefore : nil
    }
}
