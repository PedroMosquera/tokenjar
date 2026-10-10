import SwiftUI
import HeadroomCore

struct AlertsSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage(title: "Alerts") {
            Section {
                Toggle(isOn: model.configBinding(\.alerts.enabled)) {
                    Text("Send alerts")
                    Text("macOS asks for permission to show notifications the first time alerts are on.")
                }
            }

            Section {
                ThresholdRows(values: model.config.alerts.thresholds) { values in
                    model.updateConfig { $0.alerts.thresholds = SettingsLogic.normalizedThresholds(values) }
                }
            } header: {
                Text("Usage thresholds")
            } footer: {
                HelpText.footer("Fires once per window when used % crosses a threshold, and again after the window resets. Only the highest crossed threshold fires. Accounts can set their own.")
            }
            .disabled(!model.config.alerts.enabled)

            Section("Also alert when") {
                Toggle(isOn: model.configBinding(\.alerts.projectedExhaustion)) {
                    Text("A window will run out before it resets")
                    Text("Once per window, when it is at least 50% used and the pace runs out 15 minutes or more before reset.")
                }
                Toggle(isOn: model.configBinding(\.alerts.windowResets)) {
                    Text("A window resets")
                    Text("When a limit window starts over.")
                }
                Toggle(isOn: model.configBinding(\.alerts.sourceProblems)) {
                    Text("A source stops working")
                    Text("A CLI is missing or signed out. Once per problem, cleared by the next good check.")
                }
            }
            .disabled(!model.config.alerts.enabled)

            Section {
                HelpText("Nothing fires on the first check after launch; that check only sets the baseline.")
            }
        }
    }
}
