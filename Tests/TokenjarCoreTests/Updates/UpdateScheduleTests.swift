import Foundation
import Testing
@testable import TokenjarCore

private func v(_ s: String) -> AppVersion { AppVersion(s)! }

@Suite struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func manualIsNeverDue() {
        #expect(!UpdateSchedule.isDue(mode: .manual, lastCheckAt: nil, now: now))
    }

    @Test func automaticIsDueWithoutAPreviousCheck() {
        #expect(UpdateSchedule.isDue(mode: .automatic, lastCheckAt: nil, now: now))
    }

    @Test func automaticWaitsADay() {
        #expect(!UpdateSchedule.isDue(mode: .automatic, lastCheckAt: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(UpdateSchedule.isDue(mode: .automatic, lastCheckAt: now.addingTimeInterval(-24 * 3600), now: now))
    }

    @Test func aLastCheckInTheFutureIsDue() {
        #expect(UpdateSchedule.isDue(mode: .automatic, lastCheckAt: now.addingTimeInterval(3600), now: now))
    }

    @Test func notifiesANewVersionOnce() {
        let first = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: [], userInitiated: false)
        #expect(first == UpdateDecision(notify: true, notified: [v("0.4.0")]))
        let again = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: first.notified, userInitiated: false)
        #expect(again == UpdateDecision(notify: false, notified: [v("0.4.0")]))
    }

    @Test func checkNowNeverNotifiesButCountsAsNotified() {
        let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: [], userInitiated: true)
        #expect(result == UpdateDecision(notify: false, notified: [v("0.4.0")]))
    }

    @Test func anInstalledVersionAtOrPastLatestIsNotNews() {
        for installed in ["0.4.0", "0.5.0"] {
            let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v(installed), notified: [], userInitiated: false)
            #expect(result == UpdateDecision(notify: false, notified: []))
        }
    }

    @Test func aMistakenHighTagDoesNotSilenceLaterReleases() {
        let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: [v("40.0.0")], userInitiated: false)
        #expect(result == UpdateDecision(notify: true, notified: [v("0.4.0"), v("40.0.0")]))
    }

    @Test func aNewerVersionAfterANotifiedOneNotifiesAgain() {
        let result = UpdateSchedule.decide(latest: v("0.5.0"), installed: v("0.3.0"), notified: [v("0.4.0")], userInitiated: false)
        #expect(result == UpdateDecision(notify: true, notified: [v("0.4.0"), v("0.5.0")]))
    }

    /// 0.5.0 withdrawn makes GitHub report 0.4.0 again, then 0.5.0 comes back: neither is news a second time.
    @Test func aWithdrawnReleaseNeverRepeatsANotice() {
        var notified: Set<AppVersion> = []
        var notices: [String] = []
        for latest in ["0.4.0", "0.5.0", "0.4.0", "0.5.0"] {
            let result = UpdateSchedule.decide(latest: v(latest), installed: v("0.3.0"), notified: notified, userInitiated: false)
            if result.notify { notices.append(latest) }
            notified = result.notified
        }
        #expect(notices == ["0.4.0", "0.5.0"])
    }

    @Test func versionsAtOrBelowTheInstalledOneAreForgotten() {
        let result = UpdateSchedule.decide(latest: v("0.6.0"), installed: v("0.5.0"), notified: [v("0.4.0"), v("0.5.0")], userInitiated: false)
        #expect(result == UpdateDecision(notify: true, notified: [v("0.6.0")]))
    }
}
