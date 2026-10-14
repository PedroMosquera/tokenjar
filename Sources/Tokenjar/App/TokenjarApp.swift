import AppKit
import TokenjarCore

/// An AppKit entry point rather than a SwiftUI App: an App needs a scene, and a Settings scene opened its own empty
/// window for Command-comma instead of Tokenjar's Settings window.
@main
enum TokenjarApp {
    static func main() {
        if let status = StatusCommand.run(
            CommandLine.arguments, paths: AppPaths(), now: Date(), output: { print($0, terminator: "") },
            errorOutput: { FileHandle.standardError.write(Data($0.utf8)) }
        ) {
            exit(status)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        MainMenu.install(
            in: app, appName: "Tokenjar", target: delegate,
            settingsAction: #selector(AppDelegate.openSettings(_:)), quitAction: #selector(AppDelegate.requestQuit(_:))
        )
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }
}
