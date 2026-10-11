import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct MenuBarPreviewTests {
    @Test func theAmberSampleSitsAtTheAmberLevel() {
        let samples = MenuBarPreview.samples(MenuBarConfig(warnAt: 90))
        #expect(samples.map(\.title) == [Format.percent(45), Format.percent(90), Format.duration(47 * 60)])
    }

    @Test func theAmberSampleStaysAmberWhenRedIsClose() {
        let amber = MenuBarPreview.sampleEntries(MenuBarConfig(warnAt: 80, criticalAt: 85))[1]
        #expect(amber.tightest?.usedPercent == 80)
        #expect(amber.severity == .warning)
    }

    @Test func everySampleHasTheColorTheMenuBarWouldGiveIt() {
        for config in [MenuBarConfig(), MenuBarConfig(warnAt: 50, criticalAt: 60), MenuBarConfig(warnAt: 98, criticalAt: 99), MenuBarConfig(warnAt: 1, criticalAt: 2)] {
            let entries = MenuBarPreview.sampleEntries(config)
            #expect(entries.map(\.severity) == [.ok, .warning, .critical], "\(config)")
            for entry in entries {
                let window = try! #require(entry.tightest)
                #expect(entry.severity == Severity.of(window, config: config, now: MenuBarPreview.sampleTime), "\(config) at \(window.usedPercent)")
            }
        }
    }

    @Test func theCaptionMentionsTheCountdownOnlyWhenTheFullSampleShowsIt() {
        #expect(MenuBarPreview.caption(MenuBarConfig(showResetCountdownWhenFull: true)) == "Healthy, amber and full (time to reset)")
        #expect(MenuBarPreview.caption(MenuBarConfig(showResetCountdownWhenFull: false)) == "Healthy, amber and full")
    }

    @Test func voiceOverReadsTheThreeSamplesAsOneDescription() {
        #expect(MenuBarPreview.accessibilityText(MenuBarConfig(warnAt: 80)) == "Healthy at \(Format.percent(40)), amber at \(Format.percent(80)), full at \(Format.percent(100))")
    }
}
