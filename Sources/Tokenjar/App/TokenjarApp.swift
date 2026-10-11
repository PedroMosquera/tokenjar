import AppKit

/// An AppKit entry point rather than a SwiftUI App: an App needs a scene, and a Settings scene opened its own empty
/// window for Command-comma instead of Tokenjar's Settings window.
@main
enum TokenjarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        MainMenu.install(in: app, appName: "Tokenjar", settingsTarget: delegate, settingsAction: #selector(AppDelegate.openSettings(_:)))
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }
}
