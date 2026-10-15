import Foundation
import Testing
@testable import TokenjarCore

struct WindowLengthTests {
    @Test(arguments: [(300, true), (1440, true), (1441, false), (10_080, false), (nil, false)] as [(Int?, Bool)])
    func windowsOfADayOrLessAreShort(minutes: Int?, isShort: Bool) {
        #expect(UsageWindow(id: "w", label: "W", usedPercent: 10, windowMinutes: minutes).isShort == isShort)
    }
}
