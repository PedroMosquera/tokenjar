import Foundation

/// One problem a provider's status page reports for the products Tokenjar watches, already in the words the card shows.
public struct ProviderHealthItem: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case majorOutage
        case partialOutage
        case degradedPerformance
        /// A component status this build does not know. Its raw value is never shown.
        case unknown
        /// An unresolved incident filed with no components whose text names the product. It is a text match, not the
        /// provider saying a component is down, so it never counts as an outage.
        case incident
        case maintenance

        /// nil for `operational`, an empty status or none at all. Atlassian says `major_outage` where incident.io says
        /// `full_outage`.
        init?(componentStatus: String?) {
            switch componentStatus {
            case nil, "", "operational": return nil
            case "major_outage", "full_outage": self = .majorOutage
            case "partial_outage": self = .partialOutage
            case "degraded_performance": self = .degradedPerformance
            case "under_maintenance": self = .maintenance
            default: self = .unknown
            }
        }

        public var word: String {
            switch self {
            case .majorOutage: "Major outage"
            case .partialOutage: "Partial outage"
            case .degradedPerformance: "Degraded performance"
            case .unknown: "Problem"
            case .incident: "Incident"
            case .maintenance: "Maintenance"
            }
        }

        /// Lower is worse. A status this build does not know ranks with degraded performance.
        var rank: Int {
            switch self {
            case .majorOutage: 0
            case .partialOutage: 1
            case .degradedPerformance, .unknown: 2
            case .incident: 3
            case .maintenance: 4
            }
        }
    }

    public var level: Level
    /// The watched products it covers, under Tokenjar's names ("Codex CLI", never the feed's bare "CLI").
    public var names: [String]
    /// The provider's own incident or maintenance name, shown as written.
    public var title: String?
    /// When it started, so items of one level read newest first.
    public var since: Date?

    public init(level: Level, names: [String], title: String? = nil, since: Date? = nil) {
        self.level = level
        self.names = names
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed?.isEmpty == false ? trimmed : nil
        self.since = since
    }

    /// "Claude Code and claude.ai"; a fourth name and beyond become a count, "Codex CLI, Codex Web and 2 more".
    public var who: String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        case 3: "\(names[0]), \(names[1]) and \(names[2])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// "Partial outage on Claude Code: Elevated errors for Claude Opus 5.5".
    public var text: String {
        let lead = "\(level.word) on \(who)"
        return title.map { "\(lead): \($0)" } ?? lead
    }

    static func worstFirst(_ items: [ProviderHealthItem]) -> [ProviderHealthItem] {
        items.enumerated().sorted { a, b in
            if a.element.level.rank != b.element.level.rank { return a.element.level.rank < b.element.level.rank }
            let aSince = a.element.since ?? .distantPast, bSince = b.element.since ?? .distantPast
            if aSince != bSince { return aSince > bSince }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// What a status page said in one answer.
public struct ProviderHealthAnswer: Equatable, Sendable {
    /// Worst first. Empty when every watched product is operational.
    public var items: [ProviderHealthItem]
    /// When the page produced this copy, which a CDN can serve well after (see `ProviderHealthFetcher`).
    public var answeredAt: Date

    /// Past this age the row says how old the answer is. A choice, not a measurement.
    public static let ageShownAfter: TimeInterval = 5 * 60

    public init(items: [ProviderHealthItem], answeredAt: Date) {
        self.items = items
        self.answeredAt = answeredAt
    }

    public func showsAge(now: Date) -> Bool {
        now.timeIntervalSince(answeredAt) > Self.ageShownAfter
    }
}

/// One provider's status as Tokenjar last learned it. Kept in memory only.
public struct ProviderHealth: Equatable, Sendable {
    /// Popover open asks a provider again only once its last request, answered or not, is this old, so a host that keeps
    /// failing is not asked on every open. Separate from the account refresh age on purpose.
    public static let askAgainAfter: TimeInterval = 120

    /// The last answer. A failed check keeps it: learning nothing new is not news that the problem is over.
    public private(set) var answer: ProviderHealthAnswer?
    public private(set) var lastAsked: Date?
    /// Why the last check failed; nil once a check answers.
    public private(set) var lastFailure: FetchError?

    public init() {}

    public mutating func asked(at date: Date) {
        lastAsked = date
    }

    public mutating func record(_ result: Result<ProviderHealthAnswer, FetchError>) {
        switch result {
        case .success(let answer):
            self.answer = answer
            lastFailure = nil
        case .failure(let error):
            lastFailure = error
        }
    }

    /// Whether opening the popover should ask this provider now. A refresh the user starts asks regardless.
    public func isDue(now: Date) -> Bool {
        guard let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= Self.askAgainAfter
    }
}
