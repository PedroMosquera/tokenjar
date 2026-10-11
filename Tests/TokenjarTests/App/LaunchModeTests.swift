import Foundation
import Testing
@testable import Tokenjar

struct LaunchModeTests {
    @Test func plainLaunchIsTheApp() {
        #expect(LaunchMode.parse(["Tokenjar"]) == .app)
    }

    @Test func renderSnapshotsTakesTheNextArgumentAsItsFolder() {
        #expect(LaunchMode.parse(["Tokenjar", "--render-snapshots", "/tmp/out"]) == .renderSnapshots(URL(fileURLWithPath: "/tmp/out")))
    }

    @Test func probeAndScanAreDevCommands() {
        #expect(LaunchMode.parse(["Tokenjar", "--probe", "claude"]) == .devCommand)
        #expect(LaunchMode.parse(["Tokenjar", "--scan", "codex"]) == .devCommand)
    }

    /// An unset shell variable drops the folder. Falling through to a normal launch would move Headroom's folders and
    /// start probes from a command meant only to draw PNGs.
    @Test func renderSnapshotsWithoutAFolderIsRefused() {
        for args in [["Tokenjar", "--render-snapshots"], ["Tokenjar", "--render-snapshots", ""], ["Tokenjar", "--render-snapshots", "--probe"]] {
            guard case .invalid = LaunchMode.parse(args) else {
                Issue.record("\(args) should be refused")
                continue
            }
        }
    }

    @Test func renderWindowsDefaultsToPreviewDataAndEveryScreen() {
        let mode = LaunchMode.parse(["Tokenjar", "--render-windows", "/tmp/out"])
        #expect(mode == .renderWindows(WindowRenderOptions(directory: URL(fileURLWithPath: "/tmp/out"))))
    }

    @Test func renderWindowsReadsRealDataAndScreenPrefixesInAnyOrder() {
        let mode = LaunchMode.parse(["Tokenjar", "--only", "settings-general", "--render-windows", "/tmp/out", "--real-data", "--only", "popover"])
        let expected = WindowRenderOptions(directory: URL(fileURLWithPath: "/tmp/out"), realData: true, only: ["settings-general", "popover"])
        #expect(mode == .renderWindows(expected))
    }

    @Test func renderWindowsWithoutAFolderOrPrefixIsRefused() {
        let refused = [
            ["Tokenjar", "--render-windows"],
            ["Tokenjar", "--render-windows", ""],
            ["Tokenjar", "--render-windows", "--real-data"],
            ["Tokenjar", "--render-windows", "/tmp/out", "--only"],
            ["Tokenjar", "--render-windows", "/tmp/out", "--only", "--real-data"],
        ]
        for args in refused {
            guard case .invalid(let usage) = LaunchMode.parse(args) else {
                Issue.record("\(args) should be refused")
                continue
            }
            #expect(usage.contains("--render-windows <dir>"))
        }
    }

    /// Without --render-windows these would launch the app for real, which reads and writes the live data.
    @Test func renderWindowsOptionsAloneAreRefused() {
        for args in [["Tokenjar", "--real-data"], ["Tokenjar", "--only", "popover"]] {
            guard case .invalid = LaunchMode.parse(args) else {
                Issue.record("\(args) should be refused")
                continue
            }
        }
    }
}
