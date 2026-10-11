import SwiftUI
import TokenjarCore

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    // Explicit State storage: the SDK's @State is a macro whose plugin ships only with Xcode.
    private let rangeState: State<DashboardRange>
    private let groupingState: State<UsageGrouping>
    private let contentState = State(initialValue: DashboardContent())

    init(range: DashboardRange = .week, grouping: UsageGrouping = .model) {
        rangeState = State(initialValue: range)
        groupingState = State(initialValue: grouping)
    }

    private var range: DashboardRange { rangeState.wrappedValue }
    private var content: DashboardContent { contentState.wrappedValue }

    /// nil for All, and for a selection that is no longer shown on this Mac.
    private var account: AccountConfig? {
        model.dashboardSelection.flatMap { id in model.accounts.first { $0.id == id } }
    }

    private var loadKey: DashboardLoadKey {
        DashboardLoadKey(accountIDs: account.map { [$0.id] } ?? model.accounts.map(\.id), range: range, historyRevision: model.historyRevision)
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar()
                .frame(width: 230)
            Divider().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let sections = DashboardSections.make(
                        account: account, accounts: model.accounts, snapshot: account.flatMap { model.status(for: $0).snapshot }
                    )
                    header
                    if sections.history { kpis }
                    if let account { windowTiles(account) }
                    if sections.limits { limitsCard }
                    if sections.history {
                        spendCard
                        projectsCard
                    } else if let account, account.provider.isLinkOnly {
                        linkOnlyPanel(account)
                    } else {
                        Label(noHistoryMessage, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .opacity(content.key == loadKey ? 1 : 0.6)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: loadKey) {
            contentState.wrappedValue = DashboardContent.load(
                model: model, accounts: model.accounts, account: account, range: range, now: model.now, key: loadKey
            )
        }
    }

    // MARK: Header

    private var header: some View {
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
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            if let account {
                // Icon only: a titled button truncates the account name at the window's 760 pt minimum width.
                Button {
                    model.openProviderDashboard(account)
                } label: {
                    Label("Open Usage Page", systemImage: "arrow.up.forward.square")
                }
                .labelStyle(.iconOnly)
                .help("Open \(account.resolvedDashboardURL.host() ?? account.provider.displayName) in the browser")
            }
            Picker("Range", selection: rangeState.projectedValue) {
                ForEach(DashboardRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Range for the charts, tokens, requests and projects")
        }
    }

    private var headerSubtitle: String {
        guard let account else {
            let count = model.accounts.count
            return "\(count) account\(count == 1 ? "" : "s") · updated \(Format.age(of: model.lastRefreshAt, now: model.now))"
        }
        let status = model.status(for: account)
        var parts: [String] = []
        if let snapshot = status.snapshot {
            parts.append(snapshot.source)
            parts.append("updated \(Format.age(of: snapshot.fetchedAt, now: model.now))")
        }
        if let error = status.error { parts.append(error.userMessage) }
        if parts.isEmpty { parts.append("Not checked yet") }
        return parts.joined(separator: " · ")
    }

    // MARK: KPIs

    /// Wraps to more rows instead of squeezing values when the window is narrow.
    private let tileColumns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    private var kpis: some View {
        LazyVGrid(columns: tileColumns, spacing: 10) {
            costTile("Today", content.costToday, caption: "since midnight")
            costTile("7 days", content.costLastSevenDays, caption: "including today")
            costTile("This month", content.costThisMonth, caption: content.periods.thisMonth.formatted(.dateTime.month(.wide)))
            KPITile(title: "Tokens", value: Format.tokens(content.totals.tokens), caption: range.dayCaption)
            KPITile(title: "Requests", value: content.totals.requests.formatted(), caption: range.dayCaption)
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

    @ViewBuilder
    private func windowTiles(_ account: AccountConfig) -> some View {
        let windows = model.status(for: account).snapshot?.windows ?? []
        if !windows.isEmpty {
            let columns = min(windows.count, 4)
            // Grid rather than LazyVGrid, so a tile whose verdict wraps does not leave its neighbours shorter.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: windows.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(windows[start..<min(start + columns, windows.count)]) { window in
                            WindowTile(window: window, config: model.config.menuBar, now: model.now)
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
                if let message = limitsEmptyMessage {
                    DashboardEmptyState(systemImage: "chart.line.uptrend.xyaxis", message: message)
                } else {
                    LimitsChart(content: content, range: range, warnAt: model.config.menuBar.warnAt, criticalAt: model.config.menuBar.criticalAt)
                }
            }
            .frame(height: 210)
        }
    }

    private var limitsSubtitle: String {
        if account != nil { return "Used % per window, faint rules mark resets" }
        return range == .day ? "Tightest window of each account" : "Tightest window of each account, skipping windows too short for this range"
    }

    private var limitsEmptyMessage: String? {
        guard content.key != nil, content.points.isEmpty else { return nil }
        return DashboardSections.limitsEmptyMessage(
            status: account.map { model.status(for: $0) },
            anyAccountHasWindows: model.accounts.contains { !(model.status(for: $0).snapshot?.windows.isEmpty ?? true) }
        )
    }

    private var groupingOptions: [UsageGrouping] {
        account == nil ? UsageGrouping.allCases : UsageGrouping.allCases.filter { $0 != .account }
    }

    private var grouping: UsageGrouping {
        groupingOptions.contains(groupingState.wrappedValue) ? groupingState.wrappedValue : .model
    }

    private var breakdown: SpendBreakdown {
        content.spend[grouping] ?? SpendBreakdown()
    }

    private var spendCard: some View {
        DashboardCard(title: "Daily spend", subtitle: spendSubtitle) {
            Picker("Group by", selection: Binding(get: { grouping }, set: { groupingState.wrappedValue = $0 })) {
                ForEach(groupingOptions, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let message = spendEmptyMessage {
                        DashboardEmptyState(systemImage: "chart.bar.xaxis", message: message)
                    } else {
                        SpendChart(breakdown: breakdown, days: content.periods.days(of: range), colors: spendColors, labels: spendLabels)
                    }
                }
                .frame(height: 210)
                if spendEmptyMessage == nil, !breakdown.unpricedModels.isEmpty {
                    Text("Not priced: \(unpricedModelNames)")
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

    private var spendEmptyMessage: String? {
        guard content.key != nil else { return nil }
        if !breakdown.hasUsage { return "No local usage \(range.inRangePhrase)." }
        if breakdown.segments.isEmpty {
            return "No prices for these models: \(unpricedModelNames)."
        }
        return nil
    }

    private var spendLabels: [String] {
        breakdown.groups.map { DashboardMath.displayGroup($0, by: grouping, accountNames: content.accountNames) }
    }

    private var unpricedModelNames: String {
        var seen: Set<String> = []
        return breakdown.unpricedModels.map(DashboardMath.displayName).filter { seen.insert($0).inserted }.joined(separator: ", ")
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

private struct WindowTile: View {
    var window: UsageWindow
    var config: MenuBarConfig
    var now: Date

    var body: some View {
        let severity = Severity.of(window, config: config, now: now)
        VStack(alignment: .leading, spacing: 5) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Format.percent(window.usedPercent))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(severity == .ok ? Color.primary : severity.color)
            UsageBar(
                fraction: window.notStarted ? 0 : window.usedPercent / 100,
                paceFraction: Pace.compute(window, now: now).map { $0.expectedPercent / 100 },
                tint: severity.color
            )
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            // Its own line, not appended to the countdown: at three or four tiles a row the gap would truncate.
            if let verdict {
                VerdictLine(verdict: verdict, severity: verdict.severity(config: config, now: now), showsWindow: false)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardSurface()
    }

    /// None for a full window: "Limit reached, resets in" would only repeat the countdown above it.
    private var verdict: PaceVerdict? {
        guard let verdict = PaceVerdict.make(windows: [window], config: config, now: now) else { return nil }
        if case .exhausted = verdict.kind { return nil }
        return verdict
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

private extension DashboardRange {
    var inRangePhrase: String {
        switch self {
        case .day: "today or yesterday"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        }
    }
}
