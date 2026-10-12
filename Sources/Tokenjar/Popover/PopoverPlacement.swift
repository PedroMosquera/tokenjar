import AppKit

/// Where the popover belongs relative to its status item. Every rectangle is in screen coordinates.
enum PopoverPlacement {
    /// What NSPopover draws between the status item and the content: the arrow and the border. AppKit does not publish
    /// it and it was never measured, so this is an estimate meant to be generous.
    static let arrowAllowance: CGFloat = 28
    /// About what the header, a banner and the footer need. With less room than this the popover is left taller than
    /// the room rather than squeezing them.
    static let minimumHeight: CGFloat = 240

    /// The tallest content that fits under `anchor` without leaving `visibleFrame`, the anchor's screen less the menu
    /// bar and the Dock.
    static func maxContentHeight(anchor: NSRect, visibleFrame: NSRect) -> CGFloat {
        let top = min(anchor.minY, visibleFrame.maxY)
        return max(minimumHeight, (top - visibleFrame.minY - arrowAllowance).rounded(.down))
    }

    /// True when the popover reaches above the top of its status item, which sits at the top of its screen: drawn over
    /// the menu bar instead of hanging from it. The arrow may reach into the menu bar, so only past its top counts.
    static func isAboveAnchor(window: NSRect, anchor: NSRect) -> Bool {
        window.maxY > anchor.maxY
    }

    /// The popover log's line: the three frames in whole screen points, and nothing else.
    static func describe(window: NSRect, anchor: NSRect, visibleFrame: NSRect) -> String {
        "window \(points(window)) anchor \(points(anchor)) visible \(points(visibleFrame))"
    }

    private static func points(_ rect: NSRect) -> String {
        let value = { (number: CGFloat) in Int(number.rounded()) }
        return "\(value(rect.minX)),\(value(rect.minY)) \(value(rect.width))x\(value(rect.height))"
    }
}
