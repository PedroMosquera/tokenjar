import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings live in an AppKit-owned window (see WindowPresenter); this keeps Cmd-, wired.
        Settings { EmptyView() }
    }
}
