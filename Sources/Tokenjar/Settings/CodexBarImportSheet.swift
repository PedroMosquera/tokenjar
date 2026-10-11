import SwiftUI
import TokenjarCore

struct PendingCodexBarImport: Identifiable {
    let id = UUID()
    var preview: CodexBarImportPreview
    var discovered: [AccountConfig]
    var changes: [String]
}

struct CodexBarImportSheet: View {
    var changes: [String]
    var onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from CodexBar")
                .font(.headline)
            if changes.isEmpty {
                Text("Nothing to change. Tokenjar already matches CodexBar's settings.")
                    .foregroundStyle(.secondary)
            } else {
                Text("These changes will be saved to config.json:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(changes, id: \.self) { line in
                        Label(line, systemImage: "arrow.right.circle")
                    }
                }
                HelpText("CodexBar stores thresholds as % remaining; they are converted to % used.")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onImport()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
