import AppKit
import SwiftUI
import TokenjarCore

struct AlertsSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let delivery = AlertDelivery(model.notificationPermission)
        SettingsPage {
            Section {
                Toggle(isOn: model.configBinding(\.alerts.enabled)) {
                    Text("Send alerts")
                    Text("\(delivery.summary) Nothing fires on the first check after launch; that check only sets the baseline.")
                }
                .disabled(!model.canEditConfig)
                if let action = delivery.action {
                    HStack {
                        Spacer()
                        switch action {
                        case .allowBanners:
                            Button("Allow Banners") { model.requestNotificationPermission(prominent: true) }
                        case .openNotificationSettings:
                            Button("Open Notification Settings") {
                                NSWorkspace.shared.open(AlertDelivery.notificationSettingsURL(bundleID: Bundle.main.bundleIdentifier))
                            }
                        }
                    }
                }
            }

            Section("Usage thresholds") {
                ThresholdRows(
                    values: model.config.alerts.thresholds,
                    note: "Fires once per window when used % crosses a threshold, and again after the window resets. Only the highest crossed threshold fires. Accounts can set their own. Separate from the amber and red colors in General."
                ) { values in
                    model.updateConfig { $0.alerts.thresholds = SettingsLogic.normalizedThresholds(values) }
                }
            }
            .disabled(!model.config.alerts.enabled || !model.canEditConfig)

            Section("Also alert when") {
                Toggle(isOn: model.configBinding(\.alerts.projectedExhaustion)) {
                    Text("A window will run out before it resets")
                    Text("Once per window, when it is at least 50% used and the pace runs out 15 minutes or more before reset.")
                }
                Toggle(isOn: model.configBinding(\.alerts.windowResets)) {
                    Text("A window resets")
                    Text("When a limit window starts over after reaching 80% or more.")
                }
                Toggle(isOn: model.configBinding(\.alerts.sourceProblems)) {
                    Text("A source stops working")
                    Text("A CLI is missing, signed out or unsupported, a credential or subscription stops working, or its output cannot be read. Network errors, timeouts and rate limits never alert. Once per problem, cleared by the next good check.")
                }
            }
            .disabled(!model.config.alerts.enabled || !model.canEditConfig)
        }
        .onAppear { model.refreshNotificationPermission() }
        // The grant can change in System Settings while this pane is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationPermission()
        }
    }
}

/// What the Alerts pane says about how alerts reach the user, and the one fix it can offer.
struct AlertDelivery: Equatable {
    enum Action: Equatable {
        case allowBanners
        case openNotificationSettings
    }

    var summary: String
    var action: Action?

    /// nil is a grant not read yet: the default wording, but no button until it is known.
    init(_ permission: NotificationPermission?) {
        switch permission {
        case .quiet, .notDetermined, nil:
            summary = "Alerts arrive quietly in Notification Center. Allow banners to see them on screen."
            action = permission == nil ? nil : .allowBanners
        case .banners:
            summary = "Alerts show as banners and stay in Notification Center."
            action = nil
        case .denied:
            summary = "Notifications for Tokenjar are off in System Settings, so alerts are not shown."
            action = .openNotificationSettings
        case .unavailable:
            summary = "Alerts work only from the installed app in ~/Applications."
            action = nil
        }
    }

    static func notificationSettingsURL(bundleID: String?) -> URL {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        if let bundleID { components.queryItems = [URLQueryItem(name: "id", value: bundleID)] }
        return components.url!
    }
}
