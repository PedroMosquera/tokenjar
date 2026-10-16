import SwiftUI
import TokenjarCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    // Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let rangeState: State<DashboardRange>
    private let groupingState: State<UsageGrouping>
    private let weeklySpendState = State(initialValue: false)
    private let contentState = State(initialValue: DashboardContent())

    init(range: DashboardRange = .week, grouping: UsageGrouping = .model) {
        rangeState = State(initialValue: range)
        groupingState = State(initialValue: grouping)
    }

    /// Reads no clock: the pieces that count down are subviews that read `model.now`, so a tick does not rebuild the page.
    var body: some View {
        // Resolved once: `model.accounts` checks the filesystem for every account.
        let accounts = model.accounts
        // nil for All, and for a selection that is no longer shown on this Mac.
        let account = model.dashboardSelection.flatMap { id in accounts.first { $0.id == id } }
        let range = rangeState.wrappedValue
        let key = DashboardLoadKey(accountIDs: account.map { [$0.id] } ?? accounts.map(\.id), range: range, historyRevision: model.historyRevision)
        HStack(spacing: 0) {
            DashboardSidebar()
                .frame(width: 230)
            Divider().ignoresSafeArea()
            ScrollView {
                DashboardDetail(
                    account: account, accounts: accounts, content: contentState.wrappedValue,
                    range: rangeState.projectedValue, groupingSelection: groupingState.projectedValue,
                    weeklySpend: weeklySpendState.projectedValue
                )
                .padding(20)
                .opacity(DashboardLoadKey.dims(shown: contentState.wrappedValue.key, wanted: key) ? 0.6 : 1)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: key) {
            let input = DashboardContent.Input(model: model, accounts: accounts, account: account, range: range, now: model.now, key: key)
            let loaded = await Task.detached(priority: .userInitiated) { DashboardContent.load(input) }.value
            // A newer key has started its own load; this result would overwrite it with older content.
            guard !Task.isCancelled else { return }
            contentState.wrappedValue = loaded
        }
    }
}

/// The detail pane for one selection. `account` and `accounts` are resolved by the caller.
private struct DashboardDetail: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig?
    var accounts: [AccountConfig]
    var content: DashboardContent
    var rangeBinding: Binding<DashboardRange>
    var groupingSelection: Binding<UsageGrouping>
    var weeklySpend: Binding<Bool>

    init(
        account: AccountConfig?, accounts: [AccountConfig], content: DashboardContent, range: Binding<DashboardRange>,
        groupingSelection: Binding<UsageGrouping>, weeklySpend: Binding<Bool>
    ) {
        self.account = account
        self.accounts = accounts
        self.content = content
        self.rangeBinding = range
        self.groupingSelection = groupingSelection
        self.weeklySpend = weeklySpend
    }

    private var range: DashboardRange { rangeBinding.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let sections = DashboardSections.make(account: account, accounts: accounts, status: account.map { model.status(for: $0) })
            let noUsage = sections.history ? DashboardSections.historyEmptyMessage(account: account, content: content, range: range) : nil
            header(sections)
            if sections.history, noUsage == nil { kpis }
            if let account { windowTiles(account) }
            if sections.limits {
                // A spend limit's percent line barely moves in a day; what it added per period is the useful view.
                if let account, let history = content.spendLimit {
                    spendOverTimeCard(account, history)
                } else {
                    limitsCard
                }
            }
            if sections.history {
                spendCard(emptyMessage: DashboardSections.spendEmptyMessage(account: account, content: content, breakdown: breakdown, range: range))
                if noUsage == nil { projectsCard }
            } else if let account, account.provider.isLinkOnly {
                linkOnlyPanel(account)
            } else {
                Label(noHistoryMessage, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Header

    private func header(_ sections: DashboardSections) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let account {
                ProviderLogoView(provider: account.provider, size: 30)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                let title = account.map { AccountTitle(provider: $0.provider, label: $0.label, plan: model.status(for: $0).snapshot?.plan) }
                HStack(spacing: 8) {
                    Text(title?.name ?? "All accounts")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if let plan = title?.plan {
                        PlanPill(plan)
                    }
                }
                HeaderSubtitle(account: account, accountCount: accounts.count)
            }
            Spacer(minLength: 16)
            // A link-only page has its own titled button in the panel below.
            if let account, !account.provider.isLinkOnly {
                // Icon only: a titled button truncates the account name at the window's 760 pt minimum width.
                Button {
                    model.openProviderDashboard(account)
                } label: {
                    Label("Open Usage Page", systemImage: "arrow.up.forward.square")
                }
                .labelStyle(.iconOnly)
                .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
            }
            if sections.history || sections.limits {
                Picker("Range", selection: rangeBinding) {
                    ForEach(DashboardRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Range for the charts, tokens, requests and projects")
            }
        }
    }

    // MARK: KPIs

    private var kpis: some View {
        TileRowsLayout {
            costTile("Today", content.costToday, caption: "since midnight")
            costTile("7 days", content.costLastSevenDays, caption: "including today")
            costTile("This month", content.costThisMonth, caption: content.periods.thisMonth.formatted(.dateTime.month(.wide)))
            forecastTile
            if let plan = content.planValue {
                KPITile(
                    title: "Plan value", value: plan.valueText(), caption: plan.caption(), isEstimate: plan.isEstimate, help: plan.help()
                )
            }
            KPITile(title: "Tokens", value: Format.tokens(content.totals.tokens), caption: range.dayCaption)
            KPITile(title: "Requests", value: content.totals.requests.formatted(), caption: range.dayCaption)
            // Left out rather than shown as 0 % when no harness in scope reports cache tokens.
            if let rate = content.cacheHitRates.overall {
                KPITile(
                    title: "Cache hit rate", value: Format.percent(rate * 100), caption: range.dayCaption,
                    help: "Input read from cache, as a share of all input: uncached input, cache reads and cache writes"
                )
            }
        }
    }

    private func costTile(_ title: String, _ cost: CostTotal, caption: String) -> some View {
        let value: String
        var detail = caption
        var style: Color?
        if cost.hasCost {
            value = Format.money(cost.amount)
            if cost.unpricedRows > 0 { detail = "partly unpriced" }
        } else if cost.hasUsage {
            value = "No prices"
            detail = "models unpriced"
            style = .secondary
        } else {
            value = Format.money(0)
        }
        return KPITile(title: "Cost · \(title)", value: value, caption: detail, isEstimate: cost.isEstimate, valueStyle: style)
    }

    /// Says "estimate" wherever the cost tiles do, so a subscription's projection never reads as a bill.
    private var forecastTile: some View {
        let periods = content.periods
        let month = periods.thisMonth.formatted(.dateTime.month(.wide))
        let lastMonth = content.costLastMonth
        let forecast = MonthForecast.make(
            monthToDate: content.costThisMonth.amount, lastMonth: lastMonth.hasCost ? lastMonth.amount : nil,
            now: periods.now, calendar: periods.calendar
        )
        var help = "API-equivalent estimate, not a bill: \(month)'s cost so far at its average daily rate, over the whole month"
        // History that begins partway through last month makes the change look larger, so the base is named.
        if lastMonth.hasCost {
            help += ". \(periods.lastMonth.formatted(.dateTime.month(.wide))) in Tokenjar's history: \(Format.money(lastMonth.amount))"
        }
        let cost = content.costThisMonth
        if cost.hasUsage, !cost.hasCost {
            return KPITile(title: "Cost · Projected", value: "No prices", caption: "models unpriced", valueStyle: .secondary, help: help)
        }
        guard let projected = forecast.projected else {
            return KPITile(title: "Cost · Projected", value: "Too early", caption: "after 5% of \(month)", valueStyle: .secondary, help: help)
        }
        let caption = forecast.change.map {
            // Abbreviated: at the window's minimum width four tiles a row truncate "+49% vs September".
            MonthForecast.changeText($0, lastMonthName: periods.lastMonth.formatted(.dateTime.month(.abbreviated)))
        } ?? "\(month) at this pace"
        return KPITile(
            title: "Cost · Projected", value: "~" + Format.money(projected, currency: "USD", fractionDigits: 0, locale: .autoupdatingCurrent),
            caption: caption, isEstimate: cost.isEstimate, help: help
        )
    }

    @ViewBuilder
    private func windowTiles(_ account: AccountConfig) -> some View {
        let windows = model.status(for: account).snapshot?.windows ?? []
        if !windows.isEmpty {
            // At least three columns, so one or two windows do not stretch into bars as wide as the page.
            let columns = max(3, min(windows.count, 4))
            // Grid rather than LazyVGrid, so a tile whose verdict wraps does not leave its neighbours shorter.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: windows.count, by: columns)), id: \.self) { start in
                    let row = windows[start..<min(start + columns, windows.count)]
                    GridRow {
                        ForEach(row) { window in
                            WindowTile(window: window)
                                .frame(maxWidth: windows.count == 1 ? 340 : .infinity, alignment: .leading)
                        }
                        ForEach(row.count..<columns, id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var limitsCard: some View {
        DashboardCard(
            title: "Limits over time",
            subtitle: limitsSubtitle
        ) {
            Group {
                // Until the first load lands there is no domain to draw, only axis labels piled in one place.
                if content.key == nil {
                    Color.clear
                } else if let message = limitsEmptyMessage {
                    DashboardEmptyState(systemImage: "chart.line.uptrend.xyaxis", message: message)
                } else {
                    LimitsChart(content: content, range: range, warnAt: model.config.menuBar.warnAt, criticalAt: model.config.menuBar.criticalAt)
                        .equatable()
                }
            }
            .frame(height: 210)
        }
    }

    private func spendOverTimeCard(_ account: AccountConfig, _ history: DashboardContent.SpendLimitHistory) -> some View {
        let weekly = range != .day && weeklySpend.wrappedValue
        let unit: Calendar.Component = range == .day ? .hour : weekly ? .weekOfYear : .day
        let intervals = DashboardMath.spendPeriods(range: range, weekly: weekly, periods: content.periods)
        let spend = DashboardMath.recordedSpend(samples: history.samples, limit: history.limit, periods: intervals, now: content.periods.now)
        let budget = unit == .day
            ? model.status(for: account).snapshot.flatMap { model.dailySpend(for: account, snapshot: $0, now: model.now)?.budget }
            : nil
        var subtitle = "Spend added each \(unit == .hour ? "hour" : weekly ? "week" : "day"), from Tokenjar's checks of the spend limit"
        if let first = history.samples.map(\.timestamp).min(), let start = intervals.first?.start, first > start {
            subtitle += " · recorded since \(first.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return DashboardCard(title: "Spend over time", subtitle: subtitle) {
            if range != .day {
                Picker("Bars", selection: weeklySpend) {
                    Text("Daily").tag(false)
                    Text("Weekly").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } content: {
            Group {
                if spend.allSatisfy({ $0.amount == nil }) {
                    DashboardEmptyState(systemImage: "chart.bar", message: "No spend recorded in this range yet. Tokenjar records it at each check.")
                } else {
                    SpendOverTimeChart(periods: spend, unit: unit, currency: history.currency, dailyBudget: budget)
                }
            }
            .frame(height: 210)
        }
    }

    private var limitsSubtitle: String {
        var subtitle = if account != nil {
            "Used % per window, faint rules mark resets"
        } else if range == .day {
            "Tightest window of each account"
        } else {
            "Tightest window of each account, skipping windows too short for this range"
        }
        // The axis starts where the history does, so say so rather than let it read as the whole range.
        if let since = content.limitsSince {
            subtitle += " · recorded since \(since.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return subtitle
    }

    private var limitsEmptyMessage: String? {
        guard content.key != nil, content.points.isEmpty else { return nil }
        return DashboardSections.limitsEmptyMessage(
            status: account.map { model.status(for: $0) },
            anyAccountHasWindows: accounts.contains { !(model.status(for: $0).snapshot?.windows.isEmpty ?? true) }
        )
    }

    private var groupingOptions: [UsageGrouping] {
        account == nil ? UsageGrouping.allCases : UsageGrouping.allCases.filter { $0 != .account }
    }

    private var grouping: UsageGrouping {
        groupingOptions.contains(groupingSelection.wrappedValue) ? groupingSelection.wrappedValue : .model
    }

    private var breakdown: SpendBreakdown {
        content.spend[grouping] ?? SpendBreakdown()
    }

    private func spendCard(emptyMessage: String?) -> some View {
        DashboardCard(title: "Daily spend", subtitle: spendSubtitle) {
            // Regrouping an empty chart changes nothing, so the control would only invite a click that does nothing.
            if emptyMessage == nil {
                Picker("Group by", selection: Binding(get: { grouping }, set: { groupingSelection.wrappedValue = $0 })) {
                    ForEach(groupingOptions, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if content.key == nil {
                        Color.clear
                    } else if let emptyMessage {
                        DashboardEmptyState(systemImage: "chart.bar.xaxis", message: emptyMessage)
                    } else {
                        SpendChart(
                            contentKey: content.key, grouping: grouping, range: content.key?.range ?? range, breakdown: breakdown,
                            periods: content.periods, colors: spendColors, labels: spendLabels
                        )
                        .equatable()
                    }
                }
                .frame(height: 210)
                if emptyMessage == nil, grouping == .model, let line = content.cacheHitRates.modelLine(groups: breakdown.groups) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if emptyMessage == nil, !breakdown.unpricedModels.isEmpty {
                    Text("Not priced: \(breakdown.unpricedModelNames)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var spendSubtitle: String {
        breakdown.isEstimate
            ? "API-equivalent cost per day, \(range.dayCaption) · est. from public prices"
            : "Cost per day, \(range.dayCaption)"
    }

    /// A link-only account has nothing to chart, so its page is the one thing to offer.
    private func linkOnlyPanel(_ account: AccountConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.status(for: account).snapshot?.notes ?? [], id: \.self) { note in
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.openProviderDashboard(account)
            } label: {
                Label("Open Usage Page", systemImage: "arrow.up.forward.square")
            }
            .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface()
    }

    private var noHistoryMessage: String {
        guard let account else { return "None of these accounts keeps local usage logs, so there is no cost or token history to show." }
        return "\(account.provider.displayName) keeps no local usage logs, so there is no cost or token history to show."
    }

    private var spendLabels: [String] {
        breakdown.groups.map { DashboardMath.displayGroup($0, by: grouping, accountNames: content.accountNames) }
    }

    /// Accounts keep the color they have in the limits chart; other groupings color by rank in the legend.
    private var spendColors: [Color] {
        breakdown.groups.enumerated().map { index, group in
            if group == DashboardMath.otherGroup { return DashboardPalette.other }
            if grouping == .account { return DashboardPalette.series(content.accountSlotByName[group] ?? .max) }
            return DashboardPalette.spend(index)
        }
    }

    private var projectsCard: some View {
        DashboardCard(title: "Top projects", subtitle: "By cost, \(range.dayCaption)") {
            if content.key != nil, content.projects.isEmpty {
                DashboardEmptyState(systemImage: "folder", message: "No project activity \(range.inRangePhrase).")
                    .frame(height: 90)
            } else {
                TopProjectsTable(projects: content.projects)
            }
        }
    }
}

/// Reads `model.now` itself, so a tick redraws this line and not the page around it.
struct HeaderSubtitle: View {
    @Environment(AppModel.self) private var model
    var account: AccountConfig?
    var accountCount: Int

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var text: String {
        guard let account else {
            return Self.allText(accountCount: accountCount, lastUpdated: model.lastUpdated, connectivity: model.connectivity, now: model.now)
        }
        return Self.accountText(account: account, status: model.status(for: account), connectivity: model.connectivity, now: model.now)
    }

    /// All's subtitle: how many accounts and the newest successful check.
    static func allText(accountCount: Int, lastUpdated: Date?, connectivity: Connectivity, now: Date) -> String {
        let text = "\(accountCount) account\(accountCount == 1 ? "" : "s") · updated \(Format.age(of: lastUpdated, now: now))"
        return causeWords(connectivity).map { "\(text) · \($0)" } ?? text
    }

    private static func causeWords(_ connectivity: Connectivity) -> String? {
        switch connectivity {
        case .online: nil
        case .offline: "offline"
        case .noAnswer: "can't reach any provider"
        }
    }

    static func accountText(account: AccountConfig, status: AccountStatus, connectivity: Connectivity, now: Date) -> String {
        var parts: [String] = []
        if let snapshot = status.snapshot {
            parts.append(snapshot.source)
            // A link-only snapshot is built locally and says nothing new when it was made.
            if !account.provider.isLinkOnly { parts.append("updated \(Format.age(of: snapshot.fetchedAt, now: now))") }
        }
        if let error = status.error {
            // A connection error under a Mac-wide cause is that cause, said in the words All's subtitle uses.
            if !ErrorRow.isShown(error: error, provider: account.provider, connectivity: connectivity), let words = causeWords(connectivity) {
                parts.append(words)
            } else {
                parts.append(error.userMessage(provider: account.provider))
            }
        }
        if parts.isEmpty { parts.append("Not checked yet") }
        return parts.joined(separator: " · ")
    }
}

/// Reads `model.now` itself, so a tick redraws the tiles and not the page around them.
private struct WindowTile: View {
    @Environment(AppModel.self) private var model
    var window: UsageWindow

    private var config: MenuBarConfig { model.config.menuBar }
    private var now: Date { model.now }

    var body: some View {
        let severity = Severity.of(window, config: config, now: now)
        // Past its reset the snapshot still holds the old cycle's use, which the next check replaces.
        let hasReset = !window.notStarted && window.hasReset(now: now)
        VStack(alignment: .leading, spacing: 5) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if hasReset {
                Text("reset, updating")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(Format.percent(window.usedPercent))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(severity == .ok ? Color.primary : severity.color)
            }
            UsageBar(
                fraction: window.notStarted || hasReset ? 0 : window.usedPercent / 100,
                paceFraction: hasReset ? nil : Pace.compute(window, now: now).map { $0.expectedPercent / 100 },
                tint: severity.color
            )
            if !hasReset {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // Its own line, not appended to the countdown: at three or four tiles a row the gap would truncate.
            if let verdict = WindowTileText.verdict(window, config: config, now: now) {
                VerdictLine(verdict: verdict, severity: verdict.severity(config: config, now: now), showsWindow: false)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardSurface()
        .help(WindowTileText.help(window, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(WindowTileText.accessibilityValue(window, config: config, now: now))
    }

    private var resetText: String {
        if window.notStarted { return "not started" }
        guard let countdown = Format.countdown(to: window.resetsAt, now: now) else { return "no reset time" }
        return "resets in \(countdown)"
    }
}

private extension UsageGrouping {
    var title: String {
        switch self {
        case .model: "Model"
        case .harness: "Harness"
        case .project: "Project"
        case .account: "Account"
        }
    }
}

/// What a window tile says beyond what it draws: its VoiceOver value and its tooltip.
enum WindowTileText {
    /// "88% used, resets in 50 minutes, runs out ~15m before reset".
    static func accessibilityValue(_ window: UsageWindow, config: MenuBarConfig, now: Date) -> String {
        if window.notStarted { return "not started" }
        if window.hasReset(now: now) { return "reset, updating" }
        var parts = ["\(Format.percent(window.usedPercent)) used"]
        if let resetsAt = window.resetsAt { parts.append("resets in \(Format.spokenDuration(resetsAt.timeIntervalSince(now)))") }
        if let verdict = verdict(window, config: config, now: now) { parts.append(verdict.clause) }
        return parts.joined(separator: ", ")
    }

    /// The absolute reset time and the even-pace mark, which the tile only draws as a tick.
    static func help(_ window: UsageWindow, now: Date) -> String {
        if window.notStarted { return "\(window.label) has not started; it begins with the next request." }
        if window.hasReset(now: now) { return "\(window.label) has reset; the next check shows the new cycle." }
        var parts = ["\(Format.percent(window.usedPercent)) used"]
        if let pace = Pace.compute(window, now: now) { parts.append("even pace \(Format.percent(pace.expectedPercent))") }
        if let resetsAt = window.resetsAt { parts.append("resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: ", ")
    }

    /// None for a full window: "Limit reached, resets in" would only repeat the countdown.
    static func verdict(_ window: UsageWindow, config: MenuBarConfig, now: Date) -> PaceVerdict? {
        guard let verdict = PaceVerdict.make(windows: [window], config: config, now: now) else { return nil }
        if case .exhausted = verdict.kind { return nil }
        return verdict
    }
}
