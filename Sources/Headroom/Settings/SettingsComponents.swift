import SwiftUI
import HeadroomCore

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

struct SettingsPage<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HelpText: View {
    var text: String
    /// Grouped-form footers sit flush with the box edge; this lines them up with section headers.
    var inset: CGFloat = 0

    init(_ text: String) { self.text = text }

    static func footer(_ text: String) -> HelpText {
        var help = HelpText(text)
        help.inset = 10
        return help
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
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
        LabeledContent("Add threshold") {
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
        }
    }
}
