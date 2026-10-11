import SwiftUI
import TokenjarCore

struct AccountCard: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        let status = model.status(for: account)
        let refreshMinutes = account.refreshMinutes ?? model.config.refreshMinutes
        let isStale = status.isStale(now: model.popoverNow, refreshMinutes: refreshMinutes)
        VStack(alignment: .leading, spacing: 10) {
            AccountCardHeader(account: account, status: status, isStale: isStale)
            if let error = status.error {
                ErrorRow(account: account, error: error, needsAttention: status.failureNeedsAttention(now: model.popoverNow, refreshMinutes: refreshMinutes))
            }
            if let snapshot = status.snapshot {
                SnapshotBody(account: account, snapshot: snapshot, isStale: isStale)
            } else if status.error == nil {
                Text(status.isRefreshing ? "Checking usage" : "No data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(PopoverView.cardPadding)
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
                let seconds = model.popoverNow.timeIntervalSince(fetchedAt)
                let age = Format.duration(seconds)
                Label(String(age.prefix { $0 != " " }), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Last successful update \(age) ago")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PopoverSpeech.staleBadge(age: seconds))
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
            // A link card has no usage of its own, so its dashboard page would be empty.
            if !account.provider.isLinkOnly {
                Button("Show in Dashboard") { model.showDashboard(accountID: account.id) }
            }
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
        .accessibilityLabel(PopoverSpeech.menuLabel(for: account))
    }
}

private struct ErrorRow: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var error: FetchError
    /// See `AccountStatus.failureNeedsAttention`; only then does the row take the warning color.
    var needsAttention: Bool

    var body: some View {
        let actions = AccountAction.forError(error, account: account, model: model)
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                icon
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

    @ViewBuilder
    private var icon: some View {
        if error.attention == .calm {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        } else if !needsAttention {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Severity.warning.color)
        }
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
    /// Dims the bars and the chart only. Text keeps full contrast, and the header's clock badge says it is old.
    var isStale: Bool

    var body: some View {
        let now = model.popoverNow
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(
                            window: window,
                            severity: Severity.of(window, config: model.config.menuBar, now: now),
                            pace: Pace.compute(window, now: now),
                            now: now,
                            isDimmed: isStale
                        )
                    }
                }
            }
            let verdict = PaceVerdict.make(windows: snapshot.windows, config: model.config.menuBar, now: now)
            let namesWindow = VerdictLine.namesWindow(among: snapshot.windows)
            if let verdict {
                VerdictLine(verdict: verdict, severity: verdict.severity(config: model.config.menuBar, now: now), showsWindow: namesWindow)
                    .font(.callout)
            }
            chart(now: now, verdictWindowID: verdict?.window.id, namesWindow: namesWindow)
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
            if account.provider.isLinkOnly {
                Button {
                    model.openProviderDashboard(account)
                    model.closePopover()
                } label: {
                    Label("Open Usage Page", systemImage: "arrow.up.forward.square")
                }
                .controlSize(.small)
                .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
            }
            if snapshot.windows.isEmpty && snapshot.money.isEmpty && snapshot.notes.isEmpty {
                Text("No limits reported")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func chart(now: Date, verdictWindowID: String?, namesWindow: Bool) -> some View {
        // A window past its reset would chart the cycle that just ended.
        let live = snapshot.windows.filter { !$0.hasReset(now: now) }
        if let window = BurnUpChart.chartWindow(in: live, verdictWindowID: verdictWindowID), let start = BurnUpChart.cycleStart(of: window) {
            let samples = model.samples(accountID: account.id, windowID: window.id, since: start)
            let points = BurnUpChart.points(samples: samples, window: window, start: start, now: now)
            if BurnUpChart.isWorthDrawing(points, start: start, end: window.resetsAt ?? now) {
                BurnUpChart(
                    window: window, start: start, points: points, tint: Severity.of(window, config: model.config.menuBar, now: now).color,
                    caption: namesWindow && window.id != verdictWindowID ? window.label : nil, isDimmed: isStale
                )
            }
        }
    }
}

struct VerdictLine: View {
    var verdict: PaceVerdict
    var severity: Severity
    /// Off where the window is already named: a dashboard tile titled with it, or a card with one window.
    var showsWindow = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(severity == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(severity.color))
                .spoken(PopoverSpeech.severity(severity))
            message
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One Text, so a long window label wraps to a second line instead of truncating the verdict's number. The
    /// verdict itself is primary whatever the severity: secondary text is 3.9:1 on a light card, under the 4.5:1
    /// body text needs, and the icon already carries the severity.
    private var message: Text {
        let text = Text(verdict.text)
        guard showsWindow else { return text }
        return Text("\(Text(Self.windowLead(verdict.window.label)).foregroundStyle(.secondary)) \(text)")
    }

    /// A card names the verdict's window only when it shows more than one; with one, the row above names it.
    static func namesWindow(among windows: [UsageWindow]) -> Bool {
        windows.filter { !$0.notStarted }.count > 1
    }

    /// "Week:" ahead of the verdict, with non-breaking spaces so a wrap never splits the label or starts a line with
    /// its "·".
    static func windowLead(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "\u{00A0}") + ":"
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

/// What VoiceOver reads where the popover's meaning is otherwise only visual: a color, a glyph or a short badge.
enum PopoverSpeech {
    static func menuLabel(for account: AccountConfig) -> String {
        "Actions for \(AccountTitle(provider: account.provider, label: account.label).spokenName)"
    }

    static func staleBadge(age: TimeInterval) -> String {
        "Last updated \(Format.spokenDuration(age)) ago"
    }

    /// nil where the header's text already says it all.
    static func tone(_ tone: PopoverSummary.Tone) -> String? {
        switch tone {
        case .clear: "All clear"
        case .warning: "Warning"
        case .critical: "Critical"
        case .problem: "Needs attention"
        case .empty: nil
        }
    }

    /// nil for ok, where the icon only repeats the text beside it.
    static func severity(_ severity: Severity) -> String? {
        switch severity {
        case .ok: nil
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

extension View {
    /// Reads `label` for an icon whose meaning is its color, and hides it when there is nothing to add.
    @ViewBuilder
    func spoken(_ label: String?) -> some View {
        if let label { accessibilityLabel(label) } else { accessibilityHidden(true) }
    }
}
