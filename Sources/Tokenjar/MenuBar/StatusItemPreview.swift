import AppKit
import SwiftUI

/// Draws a rendered status item with the same button setup the menu bar uses, outside the menu bar.
struct StatusItemPreview: NSViewRepresentable {
    var rendered: RenderedStatusIcon

    func makeNSView(context: Context) -> NSButton {
        Self.button(rendered)
    }

    func updateNSView(_ button: NSButton, context: Context) {
        Self.apply(rendered, to: button)
    }

    static func button(_ rendered: RenderedStatusIcon) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.refusesFirstResponder = true
        // Outside a status bar NSButton draws template images mid-gray; the menu bar draws them at label contrast.
        button.contentTintColor = .labelColor
        apply(rendered, to: button)
        return button
    }

    private static func apply(_ rendered: RenderedStatusIcon, to button: NSButton) {
        button.image = rendered.image
        if rendered.attributedTitle.length > 0 { button.attributedTitle = rendered.attributedTitle } else { button.title = rendered.title }
        button.sizeToFit()
    }
}
