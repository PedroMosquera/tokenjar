import SwiftUI

struct PopoverFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button { model.showDashboard() } label: {
                Label("Dashboard", systemImage: "chart.xyaxis.line")
            }
            .keyboardShortcut("d", modifiers: .command)
            .help("Open the dashboard (⌘D)")

            Button { model.showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Open settings (⌘,)")

            Spacer()

            Button { model.quit() } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Headroom (⌘Q)")
        }
        .buttonStyle(QuietButtonStyle(padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)))
        .font(.callout)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var padding = EdgeInsets()

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, padding: padding)
    }

    private struct QuietButton: View {
        var configuration: ButtonStyleConfiguration
        var padding: EdgeInsets
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var hover = HoverState()

        var body: some View {
            configuration.label
                .padding(padding)
                .foregroundStyle(.secondary)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : hover.isHovering && isEnabled ? 0.08 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hover.isHovering = $0 }
        }
    }
}

/// Hover flag for views that cannot use `@State`: Command Line Tools ship no SwiftUIMacros plugin, and
/// `@State` expands through it.
final class HoverState: ObservableObject {
    @Published var isHovering = false
}
