import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct UpdateStatusLineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var release: ReleaseInfo {
        ReleaseInfo(version: AppVersion("0.4.0")!, pageURL: URL(string: "https://github.com/PedroMosquera/tokenjar/releases/tag/v0.4.0")!)
    }

    @Test func unknownSaysNothing() {
        #expect(UpdateStatusLine.text(.unknown, now: now) == nil)
    }

    @Test func checkingSaysSo() {
        #expect(UpdateStatusLine.text(.checking, now: now) == "Checking...")
    }

    @Test func upToDateNamesWhenItWasChecked() {
        #expect(UpdateStatusLine.text(.upToDate(checkedAt: now.addingTimeInterval(-7200)), now: now) == "Up to date · checked 2 hours ago")
    }

    @Test func aCheckFromTheLastMinuteIsJustNow() {
        #expect(UpdateStatusLine.text(.upToDate(checkedAt: now.addingTimeInterval(-20)), now: now) == "Up to date · checked just now")
    }

    @Test func availableNamesTheVersion() {
        #expect(UpdateStatusLine.text(.available(release), now: now) == "Tokenjar 0.4.0 is available")
    }

    @Test func failedNamesWhenItFailed() {
        #expect(UpdateStatusLine.text(.failed(at: now.addingTimeInterval(-86_400)), now: now) == "Couldn't check for updates · 1 day ago")
    }
}
