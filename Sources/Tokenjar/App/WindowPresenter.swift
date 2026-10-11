import AppKit
import SwiftUI

/// Owns the Dashboard and Settings windows. An accessory (LSUIElement) app must switch to the regular
/// activation policy while a window is open, or the window opens behind other apps and never becomes key.
final class WindowPresenter: NSObject, NSWindowDelegate {
    struct Spec {
        var id: String
        var title: String
        var size: NSSize
        var minSize: NSSize

        static let dashboard = Spec(id: "dashboard", title: "Tokenjar", size: NSSize(width: 980, height: 660), minSize: NSSize(width: 760, height: 520))
        static let settings = Spec(id: "settings", title: "Tokenjar Settings", size: NSSize(width: 760, height: 560), minSize: NSSize(width: 640, height: 460))
    }

    private var windows: [String: NSWindow] = [:]

    func show<Content: View>(_ spec: Spec, @ViewBuilder content: () -> Content) {
        if let window = windows[spec.id] {
            bringToFront(window)
            return
        }
        let window = Self.makeWindow(spec, controller: NSHostingController(rootView: content()))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Tokenjar.\(spec.id)")
        windows[spec.id] = window
        bringToFront(window)
    }

    /// The window `show` opens, before it is placed, restored or shown. `--render-windows` builds its captures here
    /// too, with its own window class from `make`, so they match what the app opens.
    static func makeWindow(_ spec: Spec, controller: NSViewController, make: @MainActor (NSViewController) -> NSWindow = NSWindow.init(contentViewController:)) -> NSWindow {
        let window = make(controller)
        window.title = spec.title
        window.identifier = NSUserInterfaceItemIdentifier(spec.id)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(spec.size)
        window.contentMinSize = spec.minSize
        window.isReleasedWhenClosed = false
        return window
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
