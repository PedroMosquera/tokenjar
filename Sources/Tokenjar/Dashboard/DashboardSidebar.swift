import SwiftUI
import TokenjarCore

struct DashboardSidebar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private enum Item: Hashable {
        case all
        case account(String)
    }

    /// Deselecting (Command-click on the selected row) keeps the current page rather than leaving the pane empty.
    private var selection: Binding<Item?> {
        Binding(
            get: { model.dashboardSelection.map(Item.account) ?? .all },
            set: { item in
                switch item {
                case .all: model.dashboardSelection = nil
                case .account(let id): model.dashboardSelection = id
                case nil: break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                Label("All accounts", systemImage: "square.grid.2x2")
                    .tag(Item.all)
            }
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
                        .tag(Item.account(account.id))
                }
            }
        }
        .listStyle(.sidebar)
        .focused($focused)
        .background(UnfocusedWindowWatcher { focused = true })
    }
}

/// Calls `onUnfocused` whenever its window is left with nothing focused, so the sidebar can take keyboard focus: its
/// selection then draws in the accent color and the arrow keys move between pages. It happens without the user doing
/// anything: WindowPresenter takes focus off a window it opens the first time that window becomes key.
private struct UnfocusedWindowWatcher: NSViewRepresentable {
    var onUnfocused: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        WatcherView()
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onUnfocused = onUnfocused
    }

    final class WatcherView: NSView {
        var onUnfocused: () -> Void = {}
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder) { [weak self] window, _ in
                // Later, so whatever cleared the focus has finished before the sidebar takes it.
                DispatchQueue.main.async {
                    guard window.firstResponder === window else { return }
                    self?.onUnfocused()
                }
            }
        }
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        let title = AccountTitle(provider: account.provider, label: account.label)
        // A calm failure is an answer, not a problem: it reads as a caption instead of a warning.
        let notSubscribed = model.status(for: account).error?.attention == .calm
        let caption = [title.label == nil ? nil : title.provider, notSubscribed ? "Not subscribed" : nil].compactMap { $0 }
        HStack(spacing: 8) {
            ProviderLogoView(provider: account.provider, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.label ?? title.provider)
                    .lineLimit(1)
                if !caption.isEmpty {
                    Text(caption.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .truncationMode(.tail)
            Spacer(minLength: 4)
            SidebarBadgeView(account: account)
        }
    }
}

/// An account's usage badge. The number is its tightest live window and the tint its worst window, as the menu bar
/// colors it, so a lower window that is about to run out still shows.
struct SidebarBadge: Equatable {
    var percent: String
    var severity: Severity
    /// The most urgent window and its verdict, for the tooltip and VoiceOver: "Month 61%, runs out ~11h 48m before reset".
    var detail: String

    /// nil when no window is live, so the row can show the account's error instead.
    static func make(status: AccountStatus, config: MenuBarConfig, now: Date) -> SidebarBadge? {
        guard let snapshot = status.snapshot, let tightest = snapshot.tightestWindow(now: now) else { return nil }
        let detail: String
        if let verdict = PaceVerdict.make(windows: snapshot.windows, config: config, now: now) {
            detail = "\(verdict.window.label) \(Format.percent(verdict.window.usedPercent)), \(verdict.clause)"
        } else {
            detail = "\(tightest.label) \(Format.percent(tightest.usedPercent)) used"
        }
        return SidebarBadge(
            percent: Format.percent(tightest.usedPercent),
            severity: Severity.worst(of: snapshot.windows, config: config, now: now),
            detail: detail
        )
    }
}

/// Reads `model.now` itself, so a tick redraws only the badges and not the list around them.
private struct SidebarBadgeView: View {
    @Environment(AppModel.self) private var model
    /// `.increased` on the selected row of the key window, where severity colors would clash with the accent fill.
    @Environment(\.backgroundProminence) private var prominence
    var account: AccountConfig

    var body: some View {
        let status = model.status(for: account)
        let onSelection = prominence == .increased
        if let badge = SidebarBadge.make(status: status, config: model.config.menuBar, now: model.now) {
            let severity = badge.severity
            let stale = status.isStale(now: model.now, refreshMinutes: account.refreshMinutes ?? model.config.refreshMinutes)
            Text(badge.percent)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(onSelection ? Color.white : severity == .ok ? Color.secondary : severity.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(onSelection ? Color.white.opacity(0.2) : severity == .ok ? Color.primary.opacity(0.07) : severity.color.opacity(0.16)))
                .opacity(stale ? 0.5 : 1)
                .help(badge.detail)
                .accessibilityLabel(badge.percent)
                .accessibilityValue(badge.detail)
        } else if let error = status.error, error.attention != .calm {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(error.userMessage)
                .accessibilityLabel(error.userMessage)
        }
    }
}
