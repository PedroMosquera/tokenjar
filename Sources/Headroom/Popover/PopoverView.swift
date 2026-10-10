import SwiftUI
import HeadroomCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(model.accounts) { account in
                Text(account.displayName)
            }
            Button("Quit") { model.quit() }
        }
        .padding()
        .frame(width: 360)
    }
}
