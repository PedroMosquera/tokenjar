import Foundation

/// What Tokenjar reads from one provider's status feed: which components it watches, the names it shows them under, and
/// the words that tie a component-less incident to the product.
///
/// The page-wide indicator is never read. It reflects every product on the page, so a Claude Console incident would
/// flag Claude Code users for days.
struct ProviderHealthFeed: Sendable {
    enum Format: Sendable {
        /// Atlassian Statuspage `/api/v2/summary.json`.
        case statuspage
        /// The incident.io page data behind status.openai.com, `/proxy/status.openai.com`. Undocumented.
        case incidentIO
    }

    struct Component: Sendable {
        var id: String
        var name: String
    }

    struct Group: Sendable {
        var id: String
        /// Put before a member's own name when that name lacks it, so a new "Cloud" reads "Codex Cloud".
        var prefix: String
    }

    struct ProductWord: Sendable {
        var word: String
        var name: String
    }

    var format: Format
    /// Matched by ID, never by name: names repeat (OpenAI lists two components called Login) and a name containing the
    /// product word can be another product (GitHub's Copilot AI Model Providers). In the order names are listed.
    var components: [Component]
    /// Every member of this group is watched as well, so a new product in it needs no code change.
    var group: Group?
    /// An unresolved incident filed with no components, whose impact is not none, shows when its name or one of its
    /// updates contains one of these words, ignoring case. Empty means no such incident ever shows.
    var productWords: [ProductWord]

    static func forProvider(_ provider: ProviderID) -> ProviderHealthFeed? {
        switch provider {
        case .claude:
            ProviderHealthFeed(
                format: .statuspage,
                components: [
                    Component(id: "yyzkbfz2thpt", name: "Claude Code"),
                    Component(id: "rwppv331jlwc", name: "claude.ai"),
                    Component(id: "k8w3r06qmzrp", name: "Claude API"),
                ],
                productWords: [ProductWord(word: "Claude Code", name: "Claude Code"), ProductWord(word: "claude.ai", name: "claude.ai")]
            )
        case .codex:
            // No fallback on incident text: no ongoing incident has been seen in this feed, so its shape is unknown.
            ProviderHealthFeed(
                format: .incidentIO,
                components: [
                    Component(id: "01KMKFAMWKNQ84Z1766MV08ZDE", name: "Codex CLI"),
                    Component(id: "01JVCV8YSWZFRSM1G5CVP253SK", name: "Codex Web"),
                    Component(id: "01KMP3KP5MGE23B80K1EK4S8PV", name: "Codex API"),
                    Component(id: "01KMP3KP5M8X0EBTVW6KN327EE", name: "Codex VS Code extension"),
                    Component(id: "01KMKFAMWKQ81YWSE1Z18R6VHR", name: "Codex in ChatGPT Desktop"),
                    // ChatGPT's Login, which Codex signs in through. The APIs group has its own Login, not watched.
                    Component(id: "01JMXBNJXG1S2D9V65P1ZZTD94", name: "ChatGPT login"),
                ],
                group: Group(id: "01KMKF9EBTCD8BN9PG8DJZXRSQ", prefix: "Codex"),
                productWords: []
            )
        case .copilot:
            ProviderHealthFeed(
                format: .statuspage,
                components: [Component(id: "pjmpxvq2cmr2", name: "Copilot")],
                productWords: [ProductWord(word: "Copilot", name: "Copilot")]
            )
        case .opencodeGo, .opencodeZen, .antigravity, .devin:
            nil
        }
    }

    init(format: Format, components: [Component], group: Group? = nil, productWords: [ProductWord]) {
        self.format = format
        self.components = components
        self.group = group
        self.productWords = productWords
    }

    /// Throws `FetchError.parse` when the body lacks what Tokenjar reads, a watched component included: a feed that
    /// changed under Tokenjar must not read as "all fine".
    func items(from body: Data) throws -> [ProviderHealthItem] {
        switch format {
        case .statuspage: try statuspageItems(from: body)
        case .incidentIO: try incidentIOItems(from: body)
        }
    }

    // MARK: - Atlassian Statuspage

    private struct StatuspageSummary: Decodable {
        struct Component: Decodable {
            var id: String
            var status: String?
            var updatedAt: String?
        }

        struct Reference: Decodable {
            var id: String
        }

        struct Update: Decodable {
            var body: String?
        }

        /// Incidents and scheduled maintenances share this shape.
        struct Event: Decodable {
            var name: String
            var status: String?
            var impact: String?
            var startedAt: String?
            var createdAt: String?
            var components: [Reference]?
            var incidentUpdates: [Update]?

            var componentIDs: Set<String> { Set((components ?? []).map(\.id)) }
            var start: Date? { (startedAt ?? createdAt).flatMap(DateParsing.iso8601) }
        }

        var components: [Component]
        var incidents: [Event]
        var scheduledMaintenances: [Event]
    }

    /// Items come from three rules. An unresolved incident listing a watched component that is down is one item titled
    /// by that incident. Watched components down with no incident listing them are one item together, titled by a
    /// component-less incident that names the product, if any. Any other component-less incident naming the product is
    /// an `.incident` item. Components under maintenance take the name of an in-progress maintenance that lists them.
    private func statuspageItems(from body: Data) throws -> [ProviderHealthItem] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let summary = try? decoder.decode(StatuspageSummary.self, from: body) else {
            throw FetchError.parse("summary has no components, incidents or scheduled maintenances")
        }
        var levels: [String: ProviderHealthItem.Level] = [:]
        var updated: [String: Date] = [:]
        for component in summary.components {
            if let level = ProviderHealthItem.Level(componentStatus: component.status) { levels[component.id] = level }
            updated[component.id] = component.updatedAt.flatMap(DateParsing.iso8601)
        }
        let listed = Set(summary.components.map(\.id))
        if let missing = components.first(where: { !listed.contains($0.id) }) {
            throw FetchError.parse("summary lists no component \(missing.id)")
        }

        let down = components.filter { levels[$0.id] != nil && levels[$0.id] != .maintenance }
        let underMaintenance = components.filter { levels[$0.id] == .maintenance }
        var items: [ProviderHealthItem] = []
        var covered: Set<String> = []

        for incident in summary.incidents {
            let hit = down.filter { incident.componentIDs.contains($0.id) }
            guard !hit.isEmpty else { continue }
            items.append(item(hit, levels: levels, title: incident.name, since: incident.start))
            covered.formUnion(hit.map(\.id))
        }
        for maintenance in summary.scheduledMaintenances where maintenance.status == "in_progress" || maintenance.status == "verifying" {
            let hit = underMaintenance.filter { maintenance.componentIDs.contains($0.id) }
            guard !hit.isEmpty else { continue }
            items.append(ProviderHealthItem(level: .maintenance, names: hit.map(\.name), title: maintenance.name, since: maintenance.start))
            covered.formUnion(hit.map(\.id))
        }

        var mentions: [(incident: StatuspageSummary.Event, names: [String])] = summary.incidents.compactMap { incident in
            guard incident.componentIDs.isEmpty, incident.impact != "none" else { return nil }
            let texts = [incident.name] + (incident.incidentUpdates ?? []).compactMap(\.body)
            let names = productWords.filter { word in texts.contains { $0.range(of: word.word, options: .caseInsensitive) != nil } }.map(\.name)
            return names.isEmpty ? nil : (incident, names)
        }

        let unlisted = down.filter { !covered.contains($0.id) }
        if !unlisted.isEmpty {
            let title = mentions.isEmpty ? nil : mentions.removeFirst().incident.name
            items.append(item(unlisted, levels: levels, title: title, since: unlisted.compactMap { updated[$0.id] }.max()))
        }
        let idle = underMaintenance.filter { !covered.contains($0.id) }
        if !idle.isEmpty {
            items.append(ProviderHealthItem(level: .maintenance, names: idle.map(\.name), since: idle.compactMap { updated[$0.id] }.max()))
        }
        for mention in mentions {
            items.append(ProviderHealthItem(level: .incident, names: mention.names, title: mention.incident.name, since: mention.incident.start))
        }
        return ProviderHealthItem.worstFirst(items)
    }

    // MARK: - incident.io

    private struct IncidentIOPage: Decodable {
        struct Summary: Decodable {
            struct Affected: Decodable {
                var componentId: String
                var status: String?
            }

            struct Structure: Decodable {
                var items: [Item]
            }

            struct Item: Decodable {
                var group: Group?
                var component: Member?
            }

            struct Group: Decodable {
                var id: String
                var components: [Member]?
            }

            struct Member: Decodable {
                var componentId: String
                var name: String?
            }

            var affectedComponents: [Affected]
            var structure: Structure
        }

        var summary: Summary
    }

    /// Only component status: the incidents and maintenances in this feed have never been seen with anything in them,
    /// so their titles are not read.
    private func incidentIOItems(from body: Data) throws -> [ProviderHealthItem] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let page = try? decoder.decode(IncidentIOPage.self, from: body) else {
            throw FetchError.parse("page data has no affected components or structure")
        }
        let structure = page.summary.structure.items
        var present = Set(structure.compactMap { $0.component?.componentId })
        for group in structure.compactMap(\.group) { present.formUnion((group.components ?? []).map(\.componentId)) }
        if let missing = components.first(where: { !present.contains($0.id) }) {
            throw FetchError.parse("page data lists no component \(missing.id)")
        }
        var watched = components
        if let group {
            guard let members = structure.compactMap(\.group).first(where: { $0.id == group.id })?.components else {
                throw FetchError.parse("page data has no group \(group.id)")
            }
            let known = Set(components.map(\.id))
            for member in members where !known.contains(member.componentId) {
                let name = member.name ?? ""
                let shown = name.range(of: group.prefix, options: .caseInsensitive) == nil ? "\(group.prefix) \(name)" : name
                watched.append(Component(id: member.componentId, name: shown.trimmingCharacters(in: .whitespaces)))
            }
        }

        var levels: [String: ProviderHealthItem.Level] = [:]
        for affected in page.summary.affectedComponents {
            if let level = ProviderHealthItem.Level(componentStatus: affected.status) { levels[affected.componentId] = level }
        }
        let down = watched.filter { levels[$0.id] != nil && levels[$0.id] != .maintenance }
        let underMaintenance = watched.filter { levels[$0.id] == .maintenance }
        var items: [ProviderHealthItem] = []
        if !down.isEmpty { items.append(item(down, levels: levels, title: nil, since: nil)) }
        if !underMaintenance.isEmpty { items.append(ProviderHealthItem(level: .maintenance, names: underMaintenance.map(\.name))) }
        return items
    }

    private func item(_ components: [Component], levels: [String: ProviderHealthItem.Level], title: String?, since: Date?) -> ProviderHealthItem {
        let level = components.compactMap { levels[$0.id] }.min { $0.rank < $1.rank } ?? .unknown
        return ProviderHealthItem(level: level, names: components.map(\.name), title: title, since: since)
    }
}
