import SwiftUI
import HeadroomCore

struct AccountCard: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        let status = model.status(for: account)
        let isStale = status.isStale(now: model.now, refreshMinutes: account.refreshMinutes ?? model.config.refreshMinutes)
        VStack(alignment: .leading, spacing: 10) {
            AccountCardHeader(account: account, status: status, isStale: isStale)
            if let error = status.error {
                ErrorRow(account: account, error: error)
            }
            if let snapshot = status.snapshot {
                SnapshotBody(account: account, snapshot: snapshot)
                    .opacity(isStale ? 0.5 : 1)
            } else if status.error == nil {
                Text(status.isRefreshing ? "Checking usage" : "No data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

private struct AccountCardHeader: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var status: AccountStatus
    var isStale: Bool

    @StateObject private var hover = HoverState()

    var body: some View {
        let title = AccountTitle(provider: account.provider, label: account.label, plan: status.snapshot?.plan)
        HStack(spacing: 6) {
            Button {
                model.openProviderDashboard(account)
                model.closePopover()
            } label: {
                HStack(spacing: 6) {
                    ProviderLogoView(provider: account.provider, size: 16)
                    Text(title.provider)
                        .font(.headline)
                    if let label = title.label {
                        Text(label)
                            .foregroundStyle(.secondary)
                    }
                    if let plan = title.plan {
                        PlanPill(text: plan)
                    }
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hover.isHovering ? 1 : 0)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover.isHovering = $0 }
            .help("Open \(account.provider.displayName) usage page")

            Spacer(minLength: 4)

            if status.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else if isStale, let fetchedAt = status.snapshot?.fetchedAt {
                Label(Format.age(of: fetchedAt, now: model.now), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last successful update \(Format.age(of: fetchedAt, now: model.now))")
            }
            AccountMenu(account: account)
        }
    }
}

private struct PlanPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

private struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        Menu {
            Button("Open Usage Dashboard") {
                model.openProviderDashboard(account)
                model.closePopover()
            }
            if account.provider.statusPageURL != nil {
                Button("Open Status Page") {
                    model.openStatusPage(account)
                    model.closePopover()
                }
            }
            Divider()
            Button("Show in Dashboard") { model.showDashboard(accountID: account.id) }
            Button("Settings for This Account") { model.showSettings(accountID: account.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for \(account.displayName)")
    }
}

private struct ErrorRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var error: FetchError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Severity.warning.color)
            Text(error.userMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private var action: (title: String, run: () -> Void)? {
        switch error {
        case .cliNotFound: ("Setup", { model.showSettings(accountID: account.id) })
        case .notSignedIn: ("Sign in", { model.showSettings(accountID: account.id) })
        case .unauthorized: ("Settings", { model.showSettings(accountID: account.id) })
        case .network, .timeout, .rateLimited, .parse: ("Retry", { model.refresh(force: true) })
        case .noSubscription, .unsupported: nil
        }
    }
}

private struct SnapshotBody: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var snapshot: UsageSnapshot

    var body: some View {
        let now = model.now
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(
                            window: window,
                            severity: Severity.of(window, config: model.config.menuBar, now: now),
                            pace: Pace.compute(window, now: now),
                            now: now
                        )
                    }
                }
            }
            if let verdict = PaceVerdict.make(windows: snapshot.windows, now: now) {
                VerdictLine(verdict: verdict, severity: verdictSeverity(verdict))
            }
            chart(now: now)
            if !snapshot.money.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(snapshot.money.enumerated()), id: \.offset) { _, line in
                        MoneyRow(line: line)
                    }
                }
            }
            ForEach(snapshot.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.windows.isEmpty && snapshot.money.isEmpty && snapshot.notes.isEmpty {
                Text("No limits reported")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func verdictSeverity(_ verdict: PaceVerdict) -> Severity {
        switch verdict.kind {
        case .onPace, .ahead, .under: .ok
        case .runsOut, .exhausted: max(.warning, Severity.of(verdict.window, config: model.config.menuBar, now: model.now))
        }
    }

    @ViewBuilder
    private func chart(now: Date) -> some View {
        if let window = BurnUpChart.chartWindow(in: snapshot.windows), let start = BurnUpChart.cycleStart(of: window) {
            let samples = model.samples(accountID: account.id, windowID: window.id, since: start)
            let points = BurnUpChart.points(samples: samples, window: window, start: start, now: now)
            if points.count >= 2 {
                BurnUpChart(window: window, start: start, points: points, tint: Severity.of(window, config: model.config.menuBar, now: now).color)
            }
        }
    }
}

private struct VerdictLine: View {
    var verdict: PaceVerdict
    var severity: Severity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(severity == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(severity.color))
            Text(verdict.text)
                .foregroundStyle(severity == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Text("· \(verdict.window.label)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var symbol: String {
        switch verdict.kind {
        case .onPace, .under: "checkmark.circle"
        case .ahead: "arrow.up.forward.circle"
        case .runsOut: "exclamationmark.triangle.fill"
        case .exhausted: "hourglass"
        }
    }
}

private struct MoneyRow: View {
    var line: MoneyLine

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if let limit = line.limit {
                    Text("\(Format.money(line.amount, currency: line.currency)) used of \(Format.money(limit, currency: line.currency))")
                } else {
                    Text(Format.money(line.amount, currency: line.currency))
                }
            }
            .monospacedDigit()
        }
        .font(.callout)
    }
}
