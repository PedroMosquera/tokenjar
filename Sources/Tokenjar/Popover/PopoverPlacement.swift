import AppKit

/// Where the popover belongs relative to its status item. Every rectangle is in screen coordinates.
enum PopoverPlacement {
    /// What NSPopover draws between the status item and the content: the arrow and the border. AppKit does not publish
    /// it, so this errs on the tall side.
    static let arrowAllowance: CGFloat = 28
    /// About what the header, a banner and the footer need. On a screen shorter than this the cards cannot give up
    /// enough, and AppKit moving the popover off its anchor beats squeezing the header.
    static let minimumHeight: CGFloat = 240

    /// The tallest content that fits under `anchor` without leaving `visibleFrame`, the anchor's screen less the menu
    /// bar and the Dock. A popover that does not fit there is moved beside its anchor or centered on the screen.
    static func maxContentHeight(anchor: NSRect, visibleFrame: NSRect) -> CGFloat {
        let top = min(anchor.minY, visibleFrame.maxY)
        return max(minimumHeight, (top - visibleFrame.minY - arrowAllowance).rounded(.down))
    }
}
