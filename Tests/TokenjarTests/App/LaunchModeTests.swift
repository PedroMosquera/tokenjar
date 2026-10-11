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
}
