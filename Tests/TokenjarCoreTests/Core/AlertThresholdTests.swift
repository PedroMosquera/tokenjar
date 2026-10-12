import Foundation
import Testing
@testable import TokenjarCore

struct AlertThresholdTests {
    private let account = AccountConfig(id: "claude", provider: .claude, label: "Personal")

    private func window(minutes: Int?) -> UsageWindow {
        UsageWindow(id: "w", label: "W", usedPercent: 10, windowMinutes: minutes)
    }

    /// An unknown length counts as long, so a window a provider reports without one keeps the long list.
    @Test(arguments: [(300, true), (1440, true), (1441, false), (10_080, false), (nil, false)] as [(Int?, Bool)])
    func windowsOfADayOrLessAreShort(minutes: Int?, isShort: Bool) {
        #expect(window(minutes: minutes).isShort == isShort)
    }

    @Test func shortWindowThresholdsDefaultTo95Only() {
        let config = AppConfig()
        #expect(config.thresholds(for: account, window: window(minutes: 300)) == [95])
        #expect(config.thresholds(for: account, window: window(minutes: 10_080)) == [80, 95])
    }

    @Test func eachWindowKindReadsItsOwnGlobalList() {
        let config = AppConfig(alerts: AlertConfig(thresholds: [90, 70], shortThresholds: [85, 60]))
        #expect(config.thresholds(for: account, window: window(minutes: 300)) == [60, 85])
        #expect(config.thresholds(for: account, window: window(minutes: nil)) == [70, 90])
    }

    /// An account that set its own list before the split keeps the same alerts on both kinds of window.
    @Test(arguments: [300, 1440, 10_080, nil] as [Int?])
    func anExistingOverrideStillAppliesToBothLists(minutes: Int?) {
        var overridden = account
        overridden.alertThresholds = [90, 70]
        #expect(AppConfig().thresholds(for: overridden, window: window(minutes: minutes)) == [70, 90])
    }

    @Test(arguments: [(300, [99]), (1440, [99]), (10_080, [70, 90]), (nil, [70, 90])] as [(Int?, [Int])])
    func anAccountShortOverrideWinsOnShortWindowsOnly(minutes: Int?, expected: [Int]) {
        var overridden = account
        overridden.alertThresholds = [90, 70]
        overridden.shortAlertThresholds = [99]
        #expect(AppConfig().thresholds(for: overridden, window: window(minutes: minutes)) == expected)
    }

    @Test(arguments: [(300, [99]), (10_080, [80, 95])] as [(Int?, [Int])])
    func anAccountWithOnlyAShortOverrideKeepsTheGlobalLongList(minutes: Int?, expected: [Int]) {
        var overridden = account
        overridden.shortAlertThresholds = [99]
        #expect(AppConfig().thresholds(for: overridden, window: window(minutes: minutes)) == expected)
    }
}
