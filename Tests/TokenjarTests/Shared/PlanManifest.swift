import Foundation
import Testing
import TokenjarCore

/// One row of the plan matrix, from `Fixtures/Plans/<folder>/manifest.json`. `expect` is nil until the area that owns
/// the provider writes it. Each test target carries this file; keep the copies the same apart from `folder`.
nonisolated struct PlanCase: Decodable, Sendable, CustomTestStringConvertible {
    enum Confidence: String, Decodable, Sendable { case recorded, documented, inferred }

    struct Expectation: Decodable, Sendable {
        var snapshot: UsageSnapshot?
        var error: FetchError?
        var costLine: Bool?
        var menuBar: Bool?
        var alerts: [AlertKind]?
        var headerWhenAlone: String?
    }

    var id: String
    var provider: ProviderID
    var confidence: Confidence
    var now: Date?
    /// Paths relative to `Fixtures/Plans`, or to `Fixtures` after a `fixtures:` prefix.
    var inputs: [String: String]
    /// The capture or decision the case waits for.
    var blocked: String?
    /// False for a case with no account to show, so it has no preview page row.
    var preview: Bool?
    var expect: Expectation?

    var testDescription: String { id }

    func url(_ input: String) -> URL? {
        guard let path = inputs[input] else { return nil }
        if path.hasPrefix("fixtures:") { return PlanManifest.folder.deletingLastPathComponent().appending(path: path.dropFirst(9)) }
        return PlanManifest.folder.appending(path: path)
    }
}

// Nonisolated: the app test target defaults to the main actor, and `@Test(arguments:)` reads these off it.
nonisolated enum PlanManifest {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "TokenjarCoreTests/Fixtures/Plans")

    /// Empty when a manifest fails to decode; `everyPlanRowHasOneManifestEntry` calls `load()` to show why.
    static let all: [PlanCase] = (try? load()) ?? []
    static var withExpectations: [PlanCase] { all.filter { $0.expect != nil } }
    static var windowless: [PlanCase] { withExpectations.filter { $0.expect?.snapshot?.windows.isEmpty == true } }

    static func cases(_ provider: ProviderID) -> [PlanCase] { all.filter { $0.provider == provider } }

    static func load() throws -> [PlanCase] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        return try folders.filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }.flatMap {
            try decoder.decode([PlanCase].self, from: Data(contentsOf: $0.appending(path: "manifest.json")))
        }
    }

    /// Windows that look like a 5-hour lane but whose length is missing or longer than a day: the default that alerts
    /// short windows only at 95 % cannot tell they are short.
    static func shortLaneWindowsKnowTheirLength(_ snapshot: UsageSnapshot) -> [String] {
        snapshot.windows.filter { window in
            let label = window.label.lowercased()
            let isShortLane = window.id.split(separator: ":").contains("session") || label.contains("5-hour") || label.contains("5h")
            return isShortLane && (window.windowMinutes ?? .max) > 1_440
        }.map(\.id)
    }
}
