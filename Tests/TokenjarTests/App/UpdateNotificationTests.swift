import Testing
import TokenjarCore
import UserNotifications
@testable import Tokenjar

struct UpdateNotificationTests {
    private let v030 = AppVersion("0.3.0")!
    private let v040 = AppVersion("0.4.0")!

    @Test func updateNotificationText() {
        let content = NotificationManager.updateContent(installed: v030, latest: v040)
        #expect(content.title == "Tokenjar 0.4.0 is available")
        #expect(content.body == "You have 0.3.0. Update Now installs it, or open Settings > About to see what changed.")
        #expect(content.userInfo["route"] as? String == "about")
        #expect(content.userInfo["version"] as? String == "0.4.0")
        #expect(content.categoryIdentifier == NotificationManager.updateCategoryID)
        #expect(content.threadIdentifier == "tokenjar-update")
    }

    @Test func updatedNotificationText() {
        let content = NotificationManager.updatedContent(v040)
        #expect(content.title == "Tokenjar updated to 0.4.0")
        #expect(content.body == "Open Settings > About to see what changed.")
        #expect(content.userInfo["route"] as? String == "about")
        #expect(content.userInfo["version"] == nil)
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.threadIdentifier == "tokenjar-update")
    }

    @Test func theUpdateNowActionStartsThatVersion() {
        let info = NotificationManager.updateContent(installed: v030, latest: v040).userInfo
        #expect(NotificationManager.route(info, action: NotificationManager.updateNowActionID) == .updateNow(v040))
    }

    @Test func clickingAnUpdateNoticeOnlyOpensAbout() {
        let available = NotificationManager.updateContent(installed: v030, latest: v040).userInfo
        let updated = NotificationManager.updatedContent(v040).userInfo
        #expect(NotificationManager.route(available, action: UNNotificationDefaultActionIdentifier) == .openAbout)
        #expect(NotificationManager.route(updated, action: UNNotificationDefaultActionIdentifier) == .openAbout)
        // An updated notice carries no version, so even a forged action id cannot start an update from it.
        #expect(NotificationManager.route(updated, action: NotificationManager.updateNowActionID) == .openAbout)
    }

    @MainActor @Test func eachRouteCallsOnlyItsOwnHandlers() {
        let manager = NotificationManager()
        var calls: [String] = []
        manager.onOpenDashboard = { calls.append("dashboard \($0 ?? "-")") }
        manager.onOpenAbout = { calls.append("about") }
        manager.onUpdateNow = { calls.append("update \($0)") }
        for route in [NotificationRoute.openDashboard("claude-1"), .openAbout, .updateNow(v040), nil] {
            manager.handle(route)
        }
        #expect(calls == ["dashboard claude-1", "about", "update 0.4.0", "about"])
    }

    @Test func alertsStillOpenTheDashboard() {
        let info: [AnyHashable: Any] = ["accountID": "claude-1"]
        #expect(NotificationManager.route(info, action: UNNotificationDefaultActionIdentifier) == .openDashboard("claude-1"))
        #expect(NotificationManager.route(info, action: NotificationManager.openDashboardActionID) == .openDashboard("claude-1"))
        #expect(NotificationManager.route(info, action: UNNotificationDismissActionIdentifier) == nil)
    }
}
