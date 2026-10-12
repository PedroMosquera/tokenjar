import AppKit
import SwiftUI
import Testing
@testable import Tokenjar
import TokenjarCore

// The content sits in a borderless window far off every screen that is never ordered in, and the popover is never shown.

@MainActor
private func scrollViews(in view: NSView) -> [NSScrollView] {
    if let scrollView = view as? NSScrollView { return [scrollView] }
    return view.subviews.flatMap(scrollViews)
}

@MainActor
private func spin() {
    for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor
struct PopoverScrollTests {
    /// NSPopover keeps one content controller for the app's life, so without a reset the cards reopen where they were
    /// left, with the first card cut under the header.
    @Test func everyOpenStartsAtTheTop() throws {
        _ = NSApplication.shared
        let model = AppModel.preview()
        model.secrets = SessionSecretStore(InMemorySecretStore())
        model.popoverMaxHeight = 400
        let popover = NSPopover()
        popover.contentViewController = AppDelegate.popoverContent(model)
        let controller = try #require(popover.contentViewController)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 360, height: 400), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        spin()
        #expect(!window.isVisible)

        let scrollView = try #require(scrollViews(in: controller.view).first)
        let clip = scrollView.contentView
        let top = clip.isFlipped ? 0 : (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.isFlipped ? 150 : top - 150))
        scrollView.reflectScrolledClipView(clip)
        spin()
        try #require(clip.bounds.origin.y != top, "the test needs content that scrolls")

        AppDelegate.open(popover, willOpen: { model.popoverWillOpen() }) {}
        controller.view.layoutSubtreeIfNeeded()
        spin()
        #expect(clip.bounds.origin.y == top)

        model.popoverNow = model.popoverNow.addingTimeInterval(60)
        controller.view.layoutSubtreeIfNeeded()
        spin()
        #expect(clip.bounds.origin.y == top)
        #expect(!popover.isShown)
        #expect(!window.isVisible)
        window.contentView = nil
    }
}
