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
private func scrollViews(in view: NSView) -> [NSScrollView] {
    if let scrollView = view as? NSScrollView { return [scrollView] }
    return view.subviews.flatMap(scrollViews)
}

@MainActor
struct PopoverSizingTests {
    /// NSPopover follows the content's size only through the preferred size, which the default options keep at 0x0.
    /// NSPopover itself is not checked: it follows only once it has a window, and no public call but show makes one.
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

    /// On a screen too short for the popover it asks for no more than the room under the menu bar. Which part gives
    /// up the difference is pinned by `aShortScreenKeepsTheHeaderAndFooterInside`.
    @Test func aShortScreenCapsThePopoverAtTheRoomUnderTheMenuBar() {
        let model = previewModel()
        #expect(idealSize(of: model).height > 400)

        model.popoverMaxHeight = 400

        #expect(idealSize(of: model).height == 400)
    }

    /// Laid out at the capped height, as the popover lays it out, the cards' scroll view gets shorter than its own cap
    /// and leaves the header and the footer their room. A stack that were only clipped to the cap would push the
    /// 540 pt scroll view past both edges.
    @Test func aShortScreenKeepsTheHeaderAndFooterInside() throws {
        let model = previewModel()
        model.popoverMaxHeight = 400
        let controller = AppDelegate.popoverContent(model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(scrollViews(in: controller.view).first)
        let frame = scrollView.convert(scrollView.bounds, to: controller.view)
        #expect(frame.height < PopoverView().maxCardsHeight, "scroll view \(frame)")
        #expect(min(frame.minY, 400 - frame.maxY) >= 30, "scroll view \(frame)")
    }

    @Test func roomToSpareLeavesThePopoverAsTallAsItsContent() {
        let model = previewModel()
        let free = idealSize(of: model)

        model.popoverMaxHeight = 1102

        #expect(idealSize(of: model) == free)
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
