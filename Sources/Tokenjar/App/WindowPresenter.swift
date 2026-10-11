import AppKit
import SwiftUI

/// Owns the Dashboard and Settings windows. An accessory (LSUIElement) app must switch to the regular
/// activation policy while a window is open, or the window opens behind other apps and never becomes key.
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(id: String, title: String, size: NSSize, minSize: NSSize, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Tokenjar.\(id)")
        windows[id] = window
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
