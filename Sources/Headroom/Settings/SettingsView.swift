import SwiftUI
import HeadroomCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
