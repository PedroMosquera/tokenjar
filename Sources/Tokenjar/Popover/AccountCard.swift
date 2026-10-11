import SwiftUI
import TokenjarCore

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
                        .layoutPriority(2)
                    if let label = title.label {
                        Text(label)
                            .foregroundStyle(.secondary)
                    }
                    if let plan = title.plan {
                        PlanPill(plan)
                            .layoutPriority(1)
                    }
                    if hover.isHovering {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
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
                let age = Format.duration(model.now.timeIntervalSince(fetchedAt))
                Label(String(age.prefix { $0 != " " }), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Last successful update \(age) ago")
            }
            AccountMenu(account: account)
        }
    }
}

private struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        Menu {
            Button("Open Usage Page") {
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
        let actions = AccountAction.forError(error, account: account, model: model)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Severity.warning.color)
                Text(error.userMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if actions.count == 1 {
                    buttons(actions)
                }
            }
            // Two buttons beside a long message would squeeze it into a narrow column.
            if actions.count > 1 {
                HStack(spacing: 6) { buttons(actions) }
            }
        }
        .font(.callout)
    }

    private func buttons(_ actions: [AccountAction]) -> some View {
        ForEach(actions, id: \.title) { action in
            Button(action.title, action: action.run)
                .controlSize(.small)
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
            let verdict = PaceVerdict.make(windows: snapshot.windows, config: model.config.menuBar, now: now)
            if let verdict {
                VerdictLine(verdict: verdict, severity: verdict.severity(config: model.config.menuBar, now: now))
                    .font(.callout)
            }
            chart(now: now, verdictWindowID: verdict?.window.id)
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

    @ViewBuilder
    private func chart(now: Date, verdictWindowID: String?) -> some View {
        if let window = BurnUpChart.chartWindow(in: snapshot.windows, verdictWindowID: verdictWindowID), let start = BurnUpChart.cycleStart(of: window) {
            let samples = model.samples(accountID: account.id, windowID: window.id, since: start)
            let points = BurnUpChart.points(samples: samples, window: window, start: start, now: now)
            if points.count >= 2 {
                BurnUpChart(window: window, start: start, points: points, tint: Severity.of(window, config: model.config.menuBar, now: now).color)
            }
        }
    }
}

struct VerdictLine: View {
    var verdict: PaceVerdict
    var severity: Severity
    /// Off where the window is already named, such as a dashboard tile titled with it.
    var showsWindow = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(severity == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(severity.color))
            message
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One Text, so a long window label wraps to a second line instead of truncating the verdict's number.
    private var message: Text {
        let text = Text(verdict.text).foregroundStyle(severity == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        guard showsWindow else { return text }
        return Text("\(text) \(Text(Self.windowSuffix(verdict.window.label)).foregroundStyle(.secondary))")
    }

    /// Non-breaking spaces, so a wrap moves the whole label to the next line rather than splitting it.
    static func windowSuffix(_ label: String) -> String {
        "·\u{00A0}" + label.replacingOccurrences(of: " ", with: "\u{00A0}")
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

struct MoneyRow: View {
    var line: MoneyLine

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.amount(line))
                .monospacedDigit()
        }
        .font(.callout)
    }

    static func amount(_ line: MoneyLine, locale: Locale = .autoupdatingCurrent) -> String {
        guard let limit = line.limit else { return Format.money(line.amount, currency: line.currency, locale: locale) }
        return Format.moneyUsed(line.amount, of: limit, currency: line.currency, locale: locale)
    }
}
