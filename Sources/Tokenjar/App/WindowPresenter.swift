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
        /// AppKit focuses a window's first key view the first time it becomes key. In Settings that is a field, which then
        /// shows its value selected as if the user were about to retype it. The Dashboard's is its sidebar, which needs
        /// the focus for the arrow keys to move between pages.
        var clearsFieldFocus = false

        static let dashboard = Spec(
            id: "dashboard", title: "Tokenjar Dashboard", size: NSSize(width: 980, height: 660), minSize: NSSize(width: 760, height: 520),
            autosaveName: "Tokenjar.dashboard", styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        /// Not minimizable: like System Settings, it is closed when done.
        static let settings = Spec(
            id: "settings", title: "Tokenjar Settings", size: NSSize(width: 820, height: 720), minSize: withTitleBar(SettingsView.minimumSize),
            autosaveName: "Tokenjar.settings.2", styleMask: [.titled, .closable, .resizable, .fullSizeContentView], sceneBridging: [.title],
            clearsFieldFocus: true
        )

        /// With `.fullSizeContentView` SwiftUI insets its content below the title bar, which is shorter in a binary stamped
        /// with an older SDK (a debug build), so its height is asked for here instead of written down.
        private static func withTitleBar(_ content: NSSize) -> NSSize {
            NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: content), styleMask: .titled).size
        }

        static let all = [dashboard, settings]
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
        // init(contentViewController:) binds the title to the controller's, replacing the navigationTitle SwiftUI sets
        // while attaching the content until that title changes. Content attached to a built window keeps its title.
        let window = make(Self.placeholder())
        window.unbind(.title)
        window.title = spec.title
        window.contentViewController = controller
        window.identifier = NSUserInterfaceItemIdentifier(spec.id)
        window.styleMask = spec.styleMask
        window.titlebarAppearsTransparent = true
        window.setContentSize(spec.size)
        window.contentMinSize = spec.minSize
        window.isReleasedWhenClosed = false
        return window
    }

    private static func placeholder() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue, keyed.insert(id).inserted else { return }
        Self.firstBecameKey(window)
    }

    /// What a window does the first time it becomes key. `--render-windows` runs it as each window opens.
    ///
    /// Where the spec clears field focus, the window takes the focus itself, and Tab still moves to the fields. The
    /// hosting view cannot be the initialFirstResponder: it refuses focus, and SwiftUI passes focus on to that same field.
    static func firstBecameKey(_ window: NSWindow) {
        guard Spec.all.first(where: { $0.id == window.identifier?.rawValue })?.clearsFieldFocus == true else { return }
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        keyed.remove(id)
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
