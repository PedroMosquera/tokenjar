import Foundation

/// An account's opt-in daily spending target. nil `amount` means the recommended one (`DailySpend.make`).
public struct DailyBudget: Codable, Hashable, Sendable {
    public var amount: Double?

    public init(amount: Double? = nil) {
        self.amount = amount
    }
}

/// Today's spend against the daily budget, for an account limited by what it spends. A target, not a limit: it
/// stays out of the menu bar, the header and the threshold alerts.
public struct DailySpend: Equatable, Sendable {
    public var spent: Double
    public var budget: Double
    public var isRecommended: Bool
    public var currency: String
    /// Local midnight to local midnight.
    public var dayStart: Date
    public var dayEnd: Date
    /// Set when no check from before today exists, so `spent` counts only from the first check today.
    public var countedFrom: Date?

    public static let windowID = UsageWindow.spendCapID + ":today"

    public init(
        spent: Double, budget: Double, isRecommended: Bool, currency: String, dayStart: Date, dayEnd: Date, countedFrom: Date? = nil
    ) {
        self.spent = spent
        self.budget = budget
        self.isRecommended = isRecommended
        self.currency = currency
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.countedFrom = countedFrom
    }

    /// May exceed 100: the bar keeps counting past the budget.
    public var usedPercent: Double { spent / budget * 100 }
    public var isOver: Bool { spent > budget }

    /// Today as a window, for the bar's countdown and pace mark. Over 100 % nothing stops, hence `.overage`.
    public var window: UsageWindow {
        UsageWindow(
            id: Self.windowID, label: "Today", usedPercent: usedPercent, windowMinutes: Int((dayEnd.timeIntervalSince(dayStart) / 60).rounded()),
            resetsAt: dayEnd, limitStyle: .overage
        )
    }

    /// Claude reports only the month's total, so today's spend is the total now minus the total at the last check
    /// before local midnight, from Tokenjar's own samples of the spend-limit window. nil without a spend limit, or
    /// when the recommended budget has nothing left to spread.
    public static func make(
        snapshot: UsageSnapshot, budget: DailyBudget, samples: [WindowSample], now: Date, calendar: Calendar, workWeek: WorkWeek
    ) -> DailySpend? {
        guard let window = snapshot.windows.first(where: { $0.id == UsageWindow.spendCapID }), let money = snapshot.spendLimitMoney,
              let cap = money.limit, cap > 0, let resetsAt = window.resetsAt, let minutes = window.windowMinutes,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }
        let dayStart = calendar.startOfDay(for: now)
        let cycleStart = resetsAt.addingTimeInterval(-Double(minutes) * 60)
        let cycle = samples.filter { $0.windowID == UsageWindow.spendCapID && $0.timestamp >= cycleStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        var startPercent = 0.0
        var countedFrom: Date?
        if let lastBefore = cycle.last(where: { $0.timestamp < dayStart }) {
            startPercent = lastBefore.usedPercent
        } else if cycleStart <= dayStart, let firstToday = cycle.first {
            startPercent = firstToday.usedPercent
            countedFrom = firstToday.timestamp
        }

        let spentBefore = startPercent / 100 * cap
        let spent = max(0, window.usedPercent - startPercent) / 100 * cap
        let fixed = budget.amount.flatMap { $0 > 0 ? $0 : nil }
        let target = fixed ?? (cap - spentBefore) / max(workWeek.workingSeconds(from: dayStart, to: resetsAt) / 86_400, 1)
        guard target > 0 else { return nil }
        return DailySpend(
            spent: spent, budget: target, isRecommended: fixed == nil, currency: money.currency, dayStart: dayStart, dayEnd: dayEnd,
            countedFrom: countedFrom
        )
    }
}
