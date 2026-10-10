import Foundation

public enum AlertKind: Codable, Hashable, Sendable {
    case threshold(Int)
    case projectedExhaustion
    case windowReset
    case sourceProblem
}

public struct AlertEvent: Hashable, Sendable {
    /// Notification request identifier; stable per dedupe key so re-posting replaces instead of stacking.
    public var id: String
    /// Groups notifications per account in Notification Center.
    public var threadID: String
    public var title: String
    public var body: String
    public var kind: AlertKind
    public var accountID: String
    public var windowID: String?
    /// Identifiers of delivered notifications this event supersedes (e.g. a reset clears that window's alerts).
    public var withdraws: [String]

    public init(id: String, threadID: String, title: String, body: String, kind: AlertKind, accountID: String, windowID: String? = nil, withdraws: [String] = []) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.body = body
        self.kind = kind
        self.accountID = accountID
        self.windowID = windowID
        self.withdraws = withdraws
    }
}

/// Persisted between launches so alerts are not repeated after a restart.
public struct AlertState: Codable, Equatable, Sendable {
    public var firedKeys: Set<String>
    public var baselinedAccounts: Set<String>
    public var failingAccounts: Set<String>
    /// Last seen reset per "accountID|windowID", to detect resets.
    public var lastResetsAt: [String: Date]
    public var lastUsedPercent: [String: Double]

    public init() {
        firedKeys = []
        baselinedAccounts = []
        failingAccounts = []
        lastResetsAt = [:]
        lastUsedPercent = [:]
    }
}

public enum AlertEngine {
    /// Pure: same inputs, same outputs. The first evaluation for an account only records a baseline.
    public static func evaluate(
        account: AccountConfig, result: Result<UsageSnapshot, FetchError>, config: AppConfig,
        state: inout AlertState, now: Date
    ) -> [AlertEvent] {
        []
    }
}
