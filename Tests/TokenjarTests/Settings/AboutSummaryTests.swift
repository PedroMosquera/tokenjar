import Foundation
import Testing
@testable import Tokenjar

/// Settings > About is the short form of docs/privacy.md, so a run, read or contact added to one and not the other
/// fails here. Only the item names are compared: the About pane's explanations are shorter on purpose.
@MainActor
struct AboutSummaryTests {
    private static let heading = "## The summary in Settings > About"

    @Test func runsMatchPrivacyDoc() throws {
        let documented = try Self.documented("Runs")
        #expect(documented == AboutSettingsPane.runs.map(\.what))
    }

    @Test func readsMatchPrivacyDoc() throws {
        let documented = try Self.documented("Reads")
        #expect(documented == AboutSettingsPane.reads.map(\.what))
    }

    @Test func contactsMatchPrivacyDoc() throws {
        let documented = try Self.documented("Contacts")
        #expect(documented == AboutSettingsPane.contacts.map(\.what))
    }

    /// The backticked lead of each `- ` item under `### <list>` in the summary section of docs/privacy.md, in order.
    private static func documented(_ list: String) throws -> [String] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/privacy.md")
        let lines = try String(contentsOf: doc, encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: heading), "docs/privacy.md has no \"\(heading)\" section")
        var current: String?
        var items: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("### ") {
                current = String(line.dropFirst(4))
            } else if current == list, line.hasPrefix("- `") {
                items.append(String(line.dropFirst(3).prefix { $0 != "`" }))
            }
        }
        return items
    }
}
