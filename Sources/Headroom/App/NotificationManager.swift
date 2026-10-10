import Foundation
import UserNotifications
import HeadroomCore

/// Posts alert outcomes to Notification Center and routes the "Open dashboard" action back to the app.
/// Notification Center only serves an app bundle, so every call is a no-op when running from a build folder.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "headroom.alert"
    nonisolated static let openDashboardActionID = "headroom.open-dashboard"
    nonisolated private static let accountIDKey = "accountID"

    /// Called with the alert's account id when the user taps a notification or its "Open dashboard" action.
    var onOpenDashboard: (String?) -> Void = { _ in }

    /// `UNUserNotificationCenter.current()` raises outside an app bundle, so nothing touches it unless this is true.
    var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? {
        isSupported ? UNUserNotificationCenter.current() : nil
    }

    /// Call once at launch, before a notification can be tapped, so responses reach `onOpenDashboard`.
    func activate() {
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openDashboardActionID, title: "Open dashboard", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: [])])
    }

    /// Without `prominent`, asks for provisional delivery: quiet, straight to Notification Center, no prompt.
    /// `prominent` asks for banners and sound and shows the system prompt, so pass it only when the user
    /// turns alerts on in Settings.
    @discardableResult
    func requestAuthorization(prominent: Bool) async -> Bool {
        guard let center else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized: return true
        case .denied: return false
        case .provisional where !prominent: return true
        default: break
        }
        var options: UNAuthorizationOptions = [.alert, .sound]
        if !prominent { options.insert(.provisional) }
        return (try? await center.requestAuthorization(options: options)) ?? false
    }

    /// Withdraws first: a reset's withdrawals belong to the previous cycle, never to the events posted with them.
    func handle(_ outcome: AlertOutcome) {
        withdraw(outcome.withdrawals)
        post(outcome.events)
    }

    func post(_ events: [AlertEvent]) {
        guard let center else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = event.threadID
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.accountIDKey: event.accountID]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }

    func withdraw(_ ids: [String]) {
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // An accessory app is rarely frontmost, but when the dashboard is open alerts should still show as banners.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard action == Self.openDashboardActionID || action == UNNotificationDefaultActionIdentifier else { return }
        let accountID = response.notification.request.content.userInfo[Self.accountIDKey] as? String
        await MainActor.run { onOpenDashboard(accountID) }
    }
}
