import SwiftUI
import HeadroomCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Dashboard")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
