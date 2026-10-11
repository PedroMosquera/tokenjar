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
        /// Bump its suffix when `size` grows, or a frame saved at the old size keeps opening the window too small.
        var autosaveName: String
        var styleMask: NSWindow.StyleMask
        /// What SwiftUI may set on the window; `.title` lets the content's navigationTitle name it.
        var sceneBridging: NSHostingSceneBridgingOptions = []

        static let dashboard = Spec(
            id: "dashboard", title: "Tokenjar Dashboard", size: NSSize(width: 980, height: 660), minSize: NSSize(width: 760, height: 520),
            autosaveName: "Tokenjar.dashboard", styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        /// Not minimizable: like System Settings, it is closed when done.
        static let settings = Spec(
            id: "settings", title: "Tokenjar Settings", size: NSSize(width: 820, height: 720), minSize: NSSize(width: 640, height: 460),
            autosaveName: "Tokenjar.settings.2", styleMask: [.titled, .closable, .resizable, .fullSizeContentView], sceneBridging: [.title]
        )
    }

    private var windows: [String: NSWindow] = [:]
    /// Ids of the open windows that have become key since `show` opened them.
    private var keyed: Set<String> = []

    func show<Content: View>(_ spec: Spec, @ViewBuilder content: () -> Content) {
        if let window = windows[spec.id] {
            bringToFront(window)
            return
        }
        let window = Self.makeWindow(spec, controller: Self.makeController(spec, rootView: content()))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(spec.autosaveName)
        windows[spec.id] = window
        bringToFront(window)
    }

    /// The hosting controller `show` puts in the window. `--render-windows` builds its controllers here too.
    static func makeController<Content: View>(_ spec: Spec, rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.sceneBridgingOptions = spec.sceneBridging
        return controller
    }

    /// The window `show` opens, before it is placed, restored or shown. `--render-windows` builds its captures here
    /// too, with its own window class from `make`, so they match what the app opens.
    static func makeWindow(_ spec: Spec, controller: NSViewController, make: @MainActor (NSViewController) -> NSWindow = NSWindow.init(contentViewController:)) -> NSWindow {
        let window = make(controller)
        window.title = spec.title
        window.identifier = NSUserInterfaceItemIdentifier(spec.id)
        window.styleMask = spec.styleMask
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

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue, keyed.insert(id).inserted else { return }
        Self.clearFieldFocus(in: window)
    }

    /// A window that becomes key for the first time focuses its first text field, which shows the value selected as if
    /// the user were about to retype it. The window takes focus instead, and Tab still moves to the fields. The hosting
    /// view cannot be the initialFirstResponder: it refuses focus, and SwiftUI passes focus on to that same field.
    static func clearFieldFocus(in window: NSWindow) {
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        keyed.remove(id)
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
