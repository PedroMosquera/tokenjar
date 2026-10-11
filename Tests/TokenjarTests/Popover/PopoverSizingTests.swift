import AppKit
import SwiftUI
import Testing
@testable import Tokenjar
import TokenjarCore

// Nothing here shows the popover or puts a window on screen: every size is read from controllers in no window.

@MainActor
private func previewModel() -> AppModel {
    let model = AppModel.preview()
    // The cards would otherwise read the real Keychain for a pasted key.
    model.secrets = SessionSecretStore(InMemorySecretStore())
    return model
}

/// What the popover shows for `model`, measured on its own controller, independently of the app's sizing options.
@MainActor
private func idealSize(of model: AppModel) -> NSSize {
    let controller = NSHostingController(rootView: PopoverView().environment(model))
    controller.sizingOptions = .preferredContentSize
    controller.view.layoutSubtreeIfNeeded()
    return controller.preferredContentSize
}

@MainActor
struct PopoverSizingTests {
    /// NSPopover can only follow the content's size through the preferred size; the default options keep it at 0x0.
    @Test func theContentReportsItsSizeAsItChanges() {
        let model = previewModel()
        let controller = AppDelegate.popoverContent(model)
        controller.view.layoutSubtreeIfNeeded()
        let before = controller.preferredContentSize.height

        model.showFailedReload(of: "config.json")
        controller.view.layoutSubtreeIfNeeded()

        #expect(before > 0)
        #expect(controller.preferredContentSize.height > before)
    }

    /// The popover is placed from its content size when it shows. The controller is laid out for the closed state
    /// first, as at launch, so a size read without bringing the content up to date fails as well as no size at all.
    @Test func opensAtTheSizeOfWhatItShowsOnceOpened() throws {
        _ = NSApplication.shared
        let model = previewModel()
        let popover = NSPopover()
        popover.contentViewController = AppDelegate.popoverContent(model)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        var sizeAtShow: NSSize?

        AppDelegate.open(popover, willOpen: { model.showFailedReload(of: "config.json") }) { sizeAtShow = popover.contentSize }

        let opened = idealSize(of: model)
        let shown = try #require(sizeAtShow)
        #expect(shown.width == opened.width)
        #expect(abs(shown.height - opened.height) < 0.5, "shown \(shown), content \(opened)")
        #expect(!popover.isShown)
    }
}
