import SwiftUI
import HeadroomCore

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
        DashboardLoadKey(accountIDs: account.map { [$0.id] } ?? model.accounts.map(\.id), range: range, refreshedAt: model.lastRefreshAt)
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar()
                .frame(width: 230)
                .background(Color.primary.opacity(0.035).ignoresSafeArea())
            Divider().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    kpis
                    if let account { windowTiles(account) }
                    limitsCard
                    spendCard
                    projectsCard
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
                HStack(spacing: 8) {
                    Text(account?.displayName ?? "All accounts")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if let plan = account.flatMap({ model.status(for: $0).snapshot?.plan }) {
                        PlanPill(plan)
                    }
                }
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
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

    private var hasHistorySource: Bool {
        if let account { return account.provider.harness != nil }
        return model.accounts.contains { $0.provider.harness != nil }
    }

    /// Wraps to more rows instead of squeezing values when the window is narrow.
    private let tileColumns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    private var kpis: some View {
        LazyVGrid(columns: tileColumns, spacing: 10) {
            costTile("Today", content.costToday, caption: "since midnight")
            costTile("7 days", content.costLastSevenDays, caption: "including today")
            costTile("This month", content.costThisMonth, caption: content.periods.thisMonth.formatted(.dateTime.month(.wide)))
            if hasHistorySource {
                KPITile(title: "Tokens", value: Format.tokens(content.totals.tokens), caption: range.dayCaption)
                KPITile(title: "Requests", value: content.totals.requests.formatted(), caption: range.dayCaption)
            } else {
                KPITile(title: "Tokens", value: "No history", caption: "no local usage logs", valueStyle: .secondary)
                KPITile(title: "Requests", value: "No history", caption: "no local usage logs", valueStyle: .secondary)
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
        } else if !hasHistorySource {
            value = "No history"
            detail = "no local usage logs"
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: min(windows.count, 4)), spacing: 10) {
                ForEach(windows) { window in
                    WindowTile(window: window, severity: Severity.of(window, config: model.config.menuBar, now: model.now), now: model.now)
                }
            }
        }
    }

    // MARK: Sections

    private var limitsCard: some View {
        DashboardCard(
            title: "Limits over time",
            subtitle: account == nil ? "Tightest window of each account" : "Used % per window, faint rules mark resets"
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

    private var limitsEmptyMessage: String? {
        guard content.key != nil, content.points.isEmpty else { return nil }
        if let account {
            let status = model.status(for: account)
            guard let snapshot = status.snapshot else {
                if let error = status.error { return "No limits yet. Last check: \(error.userMessage)." }
                return "No limits yet. They appear after the first refresh."
            }
            if snapshot.windows.isEmpty { return "This account reports no plan limits, only spend." }
        } else if !model.accounts.contains(where: { !(model.status(for: $0).snapshot?.windows.isEmpty ?? true) }) {
            return "No account reports plan limits yet."
        }
        return "No limit history yet. A sample is saved on every refresh."
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
                        SpendChart(breakdown: breakdown, days: content.periods.days(of: range), colors: spendColors)
                    }
                }
                .frame(height: 210)
                if spendEmptyMessage == nil, !breakdown.unpricedModels.isEmpty {
                    Text("Not priced: \(breakdown.unpricedModels.joined(separator: ", "))")
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

    private var noHistoryMessage: String? {
        guard let account, account.provider.harness == nil else { return nil }
        return "\(account.provider.displayName) keeps no local usage logs, so there is no history to show."
    }

    private var spendEmptyMessage: String? {
        guard content.key != nil else { return nil }
        if let noHistoryMessage { return noHistoryMessage }
        if !breakdown.hasUsage { return "No local usage \(range.inRangePhrase)." }
        if breakdown.segments.isEmpty {
            return "No prices for these models: \(breakdown.unpricedModels.joined(separator: ", "))."
        }
        return nil
    }

    /// Accounts keep the color they have in the limits chart; other groupings color by rank in the legend.
    private var spendColors: [Color] {
        let indexByName = Dictionary(model.accounts.enumerated().map { ($1.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        return breakdown.groups.enumerated().map { index, group in
            if group == DashboardMath.otherGroup { return DashboardPalette.other }
            if grouping == .account { return DashboardPalette.series(indexByName[group] ?? .max) }
            return DashboardPalette.spend(index)
        }
    }

    private var projectsCard: some View {
        DashboardCard(title: "Top projects", subtitle: "By cost, \(range.dayCaption)") {
            if content.key != nil, content.projects.isEmpty {
                DashboardEmptyState(systemImage: "folder", message: noHistoryMessage ?? "No project activity \(range.inRangePhrase).")
                    .frame(height: 90)
            } else {
                TopProjectsTable(projects: content.projects)
            }
        }
    }
}

private struct WindowTile: View {
    var window: UsageWindow
    var severity: Severity
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Format.percent(window.usedPercent))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(severity == .ok ? Color.primary : severity.color)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(severity.color)
                        .frame(width: proxy.size.width * min(1, max(0, window.usedPercent / 100)))
                }
            }
            .frame(height: 4)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface()
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
