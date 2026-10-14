import SwiftUI
import TokenjarCore

struct AccountCard: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig
    var burnUps: BurnUpSamples

    /// What a card with no data and no error row says.
    static func emptyText(isRefreshing: Bool, connectivity: Connectivity) -> String {
        if isRefreshing { return "Checking usage" }
        switch connectivity {
        case .online: return "No data yet"
        case .offline: return "No usage yet. Tokenjar checks when the Mac is back online."
        case .noAnswer: return "No usage yet. Tokenjar tries again at the next refresh."
        }
    }

    /// The failure the card's row shows: the latest error, else the connection failure a saved copy stands in for, so
    /// both read alike and both stay off the card under a Mac-wide cause.
    static func rowError(status: AccountStatus, provider: ProviderID, connectivity: Connectivity) -> FetchError? {
        (status.error ?? status.connectionFailure).flatMap { ErrorRow.isShown(error: $0, provider: provider, connectivity: connectivity) ? $0 : nil }
    }

    /// What the provider's status page last said, on every card of that provider and no other.
    static func healthText(provider: ProviderID, health: [ProviderID: ProviderHealth], now: Date) -> HealthRowText? {
        health[provider]?.answer.flatMap { HealthRowText(provider: provider, answer: $0, now: now) }
    }

    var body: some View {
        let status = model.status(for: account)
        let refreshMinutes = account.refreshMinutes ?? model.config.refreshMinutes
        let isStale = status.isStale(now: model.popoverNow, refreshMinutes: refreshMinutes)
        // Zen and Devin need no network, so a Mac-wide cause says nothing about them.
        let connectivity = account.provider.checkUsesNetwork ? model.connectivity : .online
        let shownError = Self.rowError(status: status, provider: account.provider, connectivity: connectivity)
        VStack(alignment: .leading, spacing: 10) {
            AccountCardHeader(account: account, status: status, isStale: isStale)
            if let shownError {
                ErrorRow(account: account, error: shownError, needsAttention: status.failureNeedsAttention(now: model.popoverNow, refreshMinutes: refreshMinutes))
            }
            if let health = Self.healthText(provider: account.provider, health: model.providerHealth, now: model.popoverNow) {
                HealthRow(account: account, text: health)
            }
            if let snapshot = status.snapshot {
                SnapshotBody(account: account, snapshot: snapshot, isStale: isStale, burnUps: burnUps)
            } else if shownError == nil {
                Text(Self.emptyText(isRefreshing: status.isRefreshing, connectivity: connectivity))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            if model.pinnedAccount?.id == account.id {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Pinned to the menu bar")
                    .accessibilityLabel("Pinned to the menu bar")
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
            PinToMenuBarToggle(account: account)
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

struct ErrorRow: View {
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
                Text(error.userMessage(provider: account.provider))
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

    private var icon: some View {
        Image(systemName: Self.symbol(for: error, needsAttention: needsAttention))
            .foregroundStyle(needsAttention ? AnyShapeStyle(Severity.warning.color) : AnyShapeStyle(.secondary))
    }

    /// Under a Mac-wide cause the header says it once, so a connection error row and its Retry, which cannot work,
    /// stay off the card. A row the user can act on, and a rate limit, are still true and stay.
    static func isShown(error: FetchError, provider: ProviderID, connectivity: Connectivity) -> Bool {
        guard connectivity != .online, provider.checkUsesNetwork else { return true }
        switch error {
        case .network, .timeout: return false
        default: return true
        }
    }

    /// A gray icon over fresh data names what Tokenjar is waiting out. Wi-Fi only for a network error: a CLI that did
    /// not answer or a provider's rate limit is not a connection problem.
    static func symbol(for error: FetchError, needsAttention: Bool) -> String {
        if error.attention == .calm { return "minus.circle" }
        if needsAttention { return "exclamationmark.triangle.fill" }
        if case .network = error { return "wifi.exclamationmark" }
        return "clock.arrow.circlepath"
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
    var burnUps: BurnUpSamples

    var body: some View {
        let now = model.popoverNow
        let spend = snapshot.spendLimitMoney
        let moneyRows = snapshot.money.filter { $0 != spend }
        VStack(alignment: .leading, spacing: 10) {
            if !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        // Past its reset the money is last month's; the row says "reset, updating" until the next check.
                        let spend = window.hasReset(now: now) ? nil : spend
                        WindowRow(
                            window: window,
                            severity: Severity.of(window, config: model.config.menuBar, now: now),
                            pace: Pace.compute(window, now: now),
                            now: now,
                            isDimmed: isStale,
                            amounts: window.id == UsageWindow.spendCapID ? spend.flatMap { line in
                                line.limit.map { Format.moneyOf(line.amount, of: $0, currency: line.currency) }
                            } : nil,
                            caption: window.id == UsageWindow.spendCapID && spend != nil ? Format.spendLimitDetail(window, money: spend, now: now) : nil
                        )
                    }
                    if let daily = model.dailySpend(for: account, snapshot: snapshot, now: now) {
                        WindowRow(
                            window: daily.window, severity: Severity.of(daily.window, config: model.config.menuBar, now: now),
                            pace: Pace.compute(daily.window, now: now), now: now, isDimmed: isStale,
                            amounts: Format.dailyAmounts(daily), caption: Format.dailyDetail(daily, now: now)
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
            if !moneyRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(moneyRows.enumerated()), id: \.offset) { _, line in
                        MoneyRow(line: line)
                    }
                }
            }
            if let costLine = model.monthCostLine(snapshot: snapshot, now: now) {
                Text(costLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
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
        // A window past its reset would chart the cycle that just ended. A spend limit's bar, pace mark and verdict
        // already say what its month line would, and the dashboard charts its spend.
        let live = snapshot.windows.filter { !$0.hasReset(now: now) }
        if snapshot.spendLimitMoney == nil, let window = BurnUpChart.chartWindow(in: live, verdictWindowID: verdictWindowID), let start = BurnUpChart.cycleStart(of: window) {
            let samples = burnUps.samples(accountID: account.id, windowID: window.id, start: start, end: window.resetsAt ?? now, revision: model.historyRevision) {
                model.samples(accountID: account.id, windowID: window.id, since: start)
            }
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
        case .runsOut, .overLimit: "exclamationmark.triangle.fill"
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
        case .empty, .unreachable, .offline, .noAnswer: nil
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

/// Pins the account to the menu bar on this Mac, for every account the menu bar can show. Pinning another moves the pin.
struct PinToMenuBarToggle: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig

    var body: some View {
        if account.showInMenuBar, account.provider.reportsWindows {
            Toggle("Pin to Menu Bar", isOn: Binding(
                get: { model.pinnedAccountID == account.id },
                set: { pinned in model.setPinnedAccount(pinned ? account.id : nil) }
            ))
        }
    }
}
