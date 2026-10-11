import AppKit
import Testing
@testable import Tokenjar

struct StrayWindowSweeperTests {
    private let screens = [NSRect(x: 0, y: 0, width: 1800, height: 1130)]

    @Test func aShownWindowOnADisplayIsAStray() {
        #expect(StrayWindowSweeper.isStray(frame: NSRect(x: 450, y: 251, width: 900, height: 450), isVisible: true, screens: screens))
    }

    @Test func aWindowPartlyOnADisplayIsAStray() {
        #expect(StrayWindowSweeper.isStray(frame: NSRect(x: -400, y: 100, width: 600, height: 300), isVisible: true, screens: screens))
    }

    @Test func aCaptureWindowParkedOffEveryDisplayIsKept() {
        #expect(!StrayWindowSweeper.isStray(frame: NSRect(x: -30_000, y: -30_000, width: 980, height: 688), isVisible: true, screens: screens))
    }

    @Test func aHiddenWindowIsKept() {
        #expect(!StrayWindowSweeper.isStray(frame: NSRect(x: 450, y: 251, width: 900, height: 450), isVisible: false, screens: screens))
    }
}
