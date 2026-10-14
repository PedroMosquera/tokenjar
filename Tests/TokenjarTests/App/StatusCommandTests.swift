import Foundation
import Testing
import TokenjarCore
@testable import Tokenjar

struct StatusCommandTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "tokenjar-status-\(UUID().uuidString)")
    var paths: AppPaths { AppPaths(home: home, environment: [:], systemRoot: home) }

    func run(_ args: [String]) -> (status: Int32?, out: String, err: String) {
        var out = "", err = ""
        let status = StatusCommand.run(args, paths: paths, now: Date(timeIntervalSince1970: 1_791_660_000), output: { out += $0 }, errorOutput: { err += $0 })
        return (status, out, err)
    }

    @Test func otherLaunchesAreNotACommand() {
        #expect(run(["Tokenjar"]).status == nil)
    }

    @Test func printsTheLastSnapshotOfEachConfiguredAccount() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: paths.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts":[{"id":"work","provider":"claude","label":"Work"}]}"#.utf8).write(to: paths.configFile)
        let store = try SQLiteUsageStore(url: paths.databaseFile)
        try store.record(UsageSnapshot(accountID: "work", provider: .claude, windows: [UsageWindow(id: "session", label: "5-hour", usedPercent: 42)], fetchedAt: Date(timeIntervalSince1970: 1_791_659_900), source: "t"))

        let result = run(["Tokenjar", "--status"])

        #expect(result.status == 0)
        #expect(result.out.contains(#""id":"work""#))
        #expect(result.out.contains(#""usedPercent":42"#))
        #expect(result.out.hasSuffix("}\n"))
    }

    @Test func noConfigYetPrintsNoAccountsAndCreatesNothing() {
        defer { try? FileManager.default.removeItem(at: home) }
        let result = run(["Tokenjar", "--status"])

        #expect(result.status == 0)
        #expect(result.out.contains(#""accounts":[]"#))
        #expect(!FileManager.default.fileExists(atPath: paths.supportDirectory.path))
    }

    @Test func anUnreadableConfigFailsWithItsReason() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: paths.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: paths.configFile)

        let result = run(["Tokenjar", "--status"])

        #expect(result.status == 1)
        #expect(result.out.isEmpty)
        #expect(result.err.contains("config.json"))
    }
}
