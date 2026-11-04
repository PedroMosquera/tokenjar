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
        let first = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: nil, userInitiated: false)
        #expect(first == UpdateDecision(notify: true, notifiedVersion: v("0.4.0")))
        let again = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: v("0.4.0"), userInitiated: false)
        #expect(again == UpdateDecision(notify: false, notifiedVersion: v("0.4.0")))
    }

    @Test func checkNowNeverNotifiesButCountsAsNotified() {
        let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: nil, userInitiated: true)
        #expect(result == UpdateDecision(notify: false, notifiedVersion: v("0.4.0")))
    }

    @Test func anInstalledVersionAtOrPastLatestIsNotNews() {
        for installed in ["0.4.0", "0.5.0"] {
            let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v(installed), notified: nil, userInitiated: false)
            #expect(result == UpdateDecision(notify: false, notifiedVersion: nil))
        }
    }

    @Test func aMistakenHighTagDoesNotSilenceLaterReleases() {
        let result = UpdateSchedule.decide(latest: v("0.4.0"), installed: v("0.3.0"), notified: v("40.0.0"), userInitiated: false)
        #expect(result == UpdateDecision(notify: true, notifiedVersion: v("0.4.0")))
    }

    @Test func aNewerVersionAfterANotifiedOneNotifiesAgain() {
        let result = UpdateSchedule.decide(latest: v("0.5.0"), installed: v("0.3.0"), notified: v("0.4.0"), userInitiated: false)
        #expect(result == UpdateDecision(notify: true, notifiedVersion: v("0.5.0")))
    }
}
