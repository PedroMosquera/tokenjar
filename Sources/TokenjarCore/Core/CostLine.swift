import Foundation

/// The popover's dollar line for an account billed per use. Decided per account from `UsageSnapshot.billing`, never
/// per model or per request: a flat plan's extra usage is already the provider's own bill, and pricing it again would
/// overstate it.
public enum CostLine {
    public enum Source: Sendable, Equatable {
        /// The provider's own figure on the snapshot.
        case snapshot
        /// Local history priced at list price.
        case history
    }

    public enum Period: Sendable, Equatable {
        /// The provider's billing cycle, as its own figure counts it.
        case providerCycle
        case calendarMonth
    }

    /// True only for an account billed per use. nil billing means the fetcher could not tell, and shows nothing.
    public static func applies(to snapshot: UsageSnapshot) -> Bool {
        switch snapshot.billing {
        case .usageBased, .payAsYouGo, .pooled: true
        case .free, .subscription, nil: false
        }
    }

    /// Where the figure comes from. Zen's money row, Copilot's overage and pooled credits, and a Codex usage-based
    /// seat's credit count are the provider's own; everything else is priced from local history.
    public static func source(for snapshot: UsageSnapshot) -> Source {
        switch snapshot.provider {
        case .opencodeZen, .copilot: .snapshot
        case .codex: snapshot.billing == .usageBased ? .snapshot : .history
        case .claude, .opencodeGo, .antigravity, .devin: .history
        }
    }

    public static func period(for snapshot: UsageSnapshot) -> Period {
        source(for: snapshot) == .snapshot ? .providerCycle : .calendarMonth
    }

    /// The wording after the amount, as in "about $4.00 list value of the org's credits". Never says "billed": an
    /// estimate or pooled credits are not this person's bill. nil for a provider's own figure, whose money line
    /// already names it.
    public static func label(for snapshot: UsageSnapshot) -> String? {
        if snapshot.billing == .pooled { return "list value of the org's credits" }
        return source(for: snapshot) == .history ? "estimate at list price" : nil
    }
}
