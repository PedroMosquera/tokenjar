import Foundation

/// A budget the user sets for a login billed per use that has no limit of its own, measured against this calendar
/// month's spend priced from local history. It is drawn as a spend limit, so the card, the menu bar, alerts and the
/// Today bar treat it as they treat a provider's own cap.
public enum MonthlyBudget {
    public static let label = "Monthly budget"

    /// True for a login whose spend Tokenjar prices from local history and that reports no spend limit of its own.
    /// A snapshot that already carries a budget's window counts, so Settings keeps the field while one is set.
    public static func applies(to snapshot: UsageSnapshot) -> Bool {
        CostLine.applies(to: snapshot) && CostLine.source(for: snapshot) == .history
            && (snapshot.spendLimitMoney == nil || snapshot.spendLimitMoney?.label == label)
    }

    /// `snapshot` with a spend-limit window and money line for `budget`. Unchanged without a positive budget, for an
    /// account whose cost is not priced from local history, or one that already reports a spend limit.
    public static func apply(_ budget: Double?, spent: Double, to snapshot: UsageSnapshot, now: Date, calendar: Calendar = .current) -> UsageSnapshot {
        guard let budget, budget > 0, applies(to: snapshot), snapshot.spendLimitMoney == nil, let month = calendar.dateInterval(of: .month, for: now) else { return snapshot }
        var out = snapshot
        out.windows.append(UsageWindow(
            id: UsageWindow.spendCapID, label: label, usedPercent: spent / budget * 100,
            windowMinutes: Int((month.duration / 60).rounded()), resetsAt: month.end, limitStyle: .overage
        ))
        out.money.append(MoneyLine(label: label, amount: spent, limit: budget))
        return out
    }
}
