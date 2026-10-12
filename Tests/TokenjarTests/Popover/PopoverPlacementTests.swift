import AppKit
import Testing
@testable import Tokenjar

struct PopoverPlacementTests {
    /// A built-in display with a 39 pt menu bar and the Dock hidden.
    private let builtIn = NSRect(x: 0, y: 0, width: 1800, height: 1130)
    private let statusItem = NSRect(x: 1500, y: 1130, width: 30, height: 39)

    @Test func theContentGetsTheVisibleFrameBelowTheStatusItemLessTheArrow() {
        #expect(PopoverPlacement.maxContentHeight(anchor: statusItem, visibleFrame: builtIn) == 1130 - PopoverPlacement.arrowAllowance)
    }

    @Test func aDockAtTheBottomTakesItsHeight() {
        let visible = NSRect(x: 0, y: 80, width: 1440, height: 820)
        let anchor = NSRect(x: 1300, y: 900, width: 30, height: 24)
        #expect(PopoverPlacement.maxContentHeight(anchor: anchor, visibleFrame: visible) == 820 - PopoverPlacement.arrowAllowance)
    }

    /// With the menu bar set to hide, the visible frame reaches the top of the screen while the menu bar is shown.
    @Test func aStatusItemBelowTheVisibleTopCountsFromItsBottomEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 1300, y: 876, width: 30, height: 24)
        #expect(PopoverPlacement.maxContentHeight(anchor: anchor, visibleFrame: visible) == 876 - PopoverPlacement.arrowAllowance)
    }

    @Test func aDisplayBelowAndBesideTheMainOneUsesItsOwnCoordinates() {
        let visible = NSRect(x: 1800, y: -1080, width: 1920, height: 1055)
        let anchor = NSRect(x: 3500, y: -25, width: 30, height: 25)
        #expect(PopoverPlacement.maxContentHeight(anchor: anchor, visibleFrame: visible) == 1055 - PopoverPlacement.arrowAllowance)
    }

    @Test func aScreenTooShortForTheHeaderAndFooterKeepsTheMinimum() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 200)
        let anchor = NSRect(x: 700, y: 200, width: 30, height: 24)
        #expect(PopoverPlacement.maxContentHeight(anchor: anchor, visibleFrame: visible) == PopoverPlacement.minimumHeight)
    }

    @Test func aFractionalRoomRoundsDownToWholePoints() {
        let visible = NSRect(x: 0, y: 0.5, width: 1512, height: 943.5)
        let anchor = NSRect(x: 1300, y: 944, width: 30, height: 38)
        #expect(PopoverPlacement.maxContentHeight(anchor: anchor, visibleFrame: visible) == (943.5 - PopoverPlacement.arrowAllowance).rounded(.down))
    }

    /// A reported screenshot: about 640 pt of popover with its top about 280 pt above the screen.
    @Test func aPopoverThatGrewOverTheMenuBarIsAboveItsAnchor() {
        let window = NSRect(x: 1335, y: 806, width: 360, height: 643)
        #expect(PopoverPlacement.isAboveAnchor(window: window, anchor: statusItem))
    }

    @Test func aPopoverHangingFromTheMenuBarIsNotAboveItsAnchor() {
        let window = NSRect(x: 1335, y: 1130 - 671, width: 360, height: 671)
        #expect(!PopoverPlacement.isAboveAnchor(window: window, anchor: statusItem))
    }

    /// The arrow may reach into the menu bar, never past the top of the status item, which is the top of the screen.
    @Test func onlyATopPastTheStatusItemCounts() {
        let window = { (top: CGFloat) in NSRect(x: 1335, y: top - 671, width: 360, height: 671) }
        #expect(!PopoverPlacement.isAboveAnchor(window: window(statusItem.maxY), anchor: statusItem))
        #expect(PopoverPlacement.isAboveAnchor(window: window(statusItem.maxY + 1), anchor: statusItem))
    }

    /// The log gets frames and nothing else, in whole points.
    @Test func theLogLineHoldsTheThreeFramesInWholePoints() {
        let line = PopoverPlacement.describe(
            window: NSRect(x: 1335.25, y: 459, width: 360, height: 671.5), anchor: statusItem, visibleFrame: builtIn
        )
        #expect(line == "window 1335,459 360x672 anchor 1500,1130 30x39 visible 0,0 1800x1130")
    }
}
