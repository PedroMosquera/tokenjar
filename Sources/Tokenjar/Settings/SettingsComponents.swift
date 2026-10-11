import SwiftUI
import TokenjarCore

/// `@State` resolves to a SwiftUI macro in the macOS 27 SDK, and Command Line Tools ship no SwiftUIMacros plugin.
/// Naming the wrapper type through an alias selects the property wrapper instead.
typealias SettingsState<Value> = SwiftUI.State<Value>

extension AppModel {
    /// Every Settings control saves through `updateConfig`, so all edits reach config.json the same way.
    func configBinding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in self.updateConfig { $0[keyPath: keyPath] = value } })
    }

    func updateAccount(_ id: String, _ edit: (inout AccountConfig) -> Void) {
        updateConfig { config in
            guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
            edit(&config.accounts[index])
        }
    }

    func accountBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<AccountConfig, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.config.accounts.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in self.updateAccount(id) { $0[keyPath: keyPath] = value } }
        )
    }
}

/// A pane's grouped form. The pane's name is the window title (`SettingsView` sets it), not a heading in the content.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Secondary text outside a form, such as in a sheet. Inside a form, a note about a control is that control's
/// second label Text, so it lines up with every other row's subtitle.
struct HelpText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A form row with no control: a title and its subtitle, laid out like every labelled control's label.
struct TextRow<Label: View>: View {
    @ViewBuilder var label: Label

    var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            label
        }
    }
}

/// Edits a draft and saves on Return or when focus leaves, so typing does not rewrite config.json on every keystroke.
struct CommittingTextField: View {
    var title: String
    var prompt: String?
    var value: String
    var monospaced = false
    var onCommit: (String) -> Void

    @SettingsState private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: Binding(get: { draft ?? value }, set: { draft = $0 }), prompt: prompt.map { Text($0) })
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard let pending = draft else { return }
        draft = nil
        if pending != value { onCommit(pending) }
    }
}

struct PercentField: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Text("%").foregroundStyle(.secondary)
                Stepper(title, value: clamped, in: range).labelsHidden()
            }
        }
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

struct ThresholdRows: View {
    var values: [Int]
    /// Shown under Add threshold, the row that sets them.
    var note: String?
    var onChange: ([Int]) -> Void

    @SettingsState private var candidate = 90

    var body: some View {
        ForEach(values, id: \.self) { value in
            LabeledContent("\(value)% used") {
                Button {
                    onChange(values.filter { $0 != value })
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(value)%")
            }
        }
        if values.isEmpty {
            Text("No thresholds").foregroundStyle(.secondary)
        }
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Threshold", value: $candidate, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Text("%").foregroundStyle(.secondary)
                Stepper("Threshold", value: $candidate, in: SettingsLogic.thresholdRange).labelsHidden()
                Button("Add") { onChange(SettingsLogic.normalizedThresholds(values + [candidate])) }
                    .disabled(values.contains(candidate) || !SettingsLogic.thresholdRange.contains(candidate))
            }
        } label: {
            Text("Add threshold")
            if let note { Text(note) }
        }
    }
}
