import Foundation
import UserNotifications
import TokenjarCore

/// How alerts reach the user. A default config has alerts on, so a new user only ever gets the quiet provisional
/// grant until something asks for banners; Settings needs to tell those apart.
enum NotificationPermission: Equatable {
    /// Running outside an app bundle, where Notification Center does not serve the app.
    case unavailable
    case notDetermined
    /// Provisional: delivered to Notification Center without banners or sound.
    case quiet
    case banners
    case denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .banners
        case .provisional: self = .quiet
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }
}

/// Posts alert outcomes to Notification Center and routes the "Open Dashboard" action back to the app.
/// Notification Center only serves an app bundle, so every call is a no-op when running from a build folder.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "tokenjar.alert"
    nonisolated static let openDashboardActionID = "tokenjar.open-dashboard"
    nonisolated private static let accountIDKey = "accountID"
    nonisolated private static let routeKey = "route"
    nonisolated private static let aboutRoute = "about"
    nonisolated private static let updateThreadID = "tokenjar-update"

    /// Called with the alert's account id when the user taps a notification or its "Open Dashboard" action.
    var onOpenDashboard: (String?) -> Void = { _ in }

    var onOpenAbout: () -> Void = {}

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
        let open = UNNotificationAction(identifier: Self.openDashboardActionID, title: "Open Dashboard", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryID, actions: [open], intentIdentifiers: [])])
    }

    /// Without `prominent`, asks for provisional delivery: quiet, straight to Notification Center, no prompt.
    /// `prominent` asks for banners and sound and shows the system prompt, so pass it only from a user action.
    @discardableResult
    func requestAuthorization(prominent: Bool) async -> NotificationPermission {
        guard let center else { return .unavailable }
        let current = await permission()
        switch current {
        case .banners, .denied, .unavailable: return current
        case .quiet where !prominent: return current
        default: break
        }
        var options: UNAuthorizationOptions = [.alert, .sound]
        if !prominent { options.insert(.provisional) }
        _ = try? await center.requestAuthorization(options: options)
        return await permission()
    }

    /// Reads the current grant without asking for anything.
    func permission() async -> NotificationPermission {
        guard let center else { return .unavailable }
        return NotificationPermission(await center.notificationSettings().authorizationStatus)
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

    static func updateContent(installed: AppVersion, latest: AppVersion) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Tokenjar \(latest) is available"
        content.body = "You have \(installed). Open Settings > About to see what changed and how to update."
        content.threadIdentifier = updateThreadID
        content.userInfo = [routeKey: aboutRoute]
        content.sound = .default
        return content
    }

    /// Not gated on the alerts setting: choosing Automatic update checks is the opt-in. One request per version, so
    /// a version that is already delivered is replaced rather than repeated.
    func postUpdate(installed: AppVersion, latest: AppVersion) {
        guard let center else { return }
        let content = Self.updateContent(installed: installed, latest: latest)
        center.add(UNNotificationRequest(identifier: "tokenjar|update|\(latest)", content: content, trigger: nil))
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
        let userInfo = response.notification.request.content.userInfo
        if userInfo[Self.routeKey] as? String == Self.aboutRoute {
            await MainActor.run { onOpenAbout() }
            return
        }
        let action = response.actionIdentifier
        guard action == Self.openDashboardActionID || action == UNNotificationDefaultActionIdentifier else { return }
        let accountID = userInfo[Self.accountIDKey] as? String
        await MainActor.run { onOpenDashboard(accountID) }
    }
}
