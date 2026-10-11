import Foundation
import Testing
@testable import TokenjarCore

struct LegacyMigrationTests {
    private let home: TempHome
    private let paths: AppPaths

    init() throws {
        home = try TempHome()
        paths = AppPaths(home: home.url, environment: [:])
    }

    private let oldSupport = "Library/Application Support/Headroom"
    private let newSupport = "Library/Application Support/Tokenjar"

    private func exists(_ relative: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: home.url.appending(path: relative).path)) != nil
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: home.url.appending(path: relative), encoding: .utf8)
    }

    private func linkDestination(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: home.url.appending(path: relative).path)
    }

    @Test func movesTheSupportFolderAndRenamesTheDatabaseFilesTogether() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try home.write("\(oldSupport)/headroom.sqlite-wal", "wal")
        try home.write("\(oldSupport)/headroom.sqlite-shm", "shm")
        try home.write("\(oldSupport)/alert-state.json", "alerts")
        try home.write("\(oldSupport)/probe-latch.json", "latch")
        try home.makeDirectory("\(oldSupport)/probe")

        let events = LegacyMigration.run(paths: paths, legacyAppIsRunning: false)

        #expect(events == [.movedSupportFolder, .renamedDatabase])
        #expect(!exists(oldSupport))
        #expect(read("\(newSupport)/tokenjar.sqlite") == "db")
        #expect(read("\(newSupport)/tokenjar.sqlite-wal") == "wal")
        #expect(read("\(newSupport)/tokenjar.sqlite-shm") == "shm")
        #expect(!exists("\(newSupport)/headroom.sqlite") && !exists("\(newSupport)/headroom.sqlite-wal") && !exists("\(newSupport)/headroom.sqlite-shm"))
        #expect(read("\(newSupport)/alert-state.json") == "alerts")
        #expect(read("\(newSupport)/probe-latch.json") == "latch")
        #expect(exists("\(newSupport)/probe"))
        #expect(paths.databaseFile.path == home.url.appending(path: "\(newSupport)/tokenjar.sqlite").path)
    }

    @Test func databaseFilesThatAreMissingAreSkipped() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")

        let events = LegacyMigration.run(paths: paths, legacyAppIsRunning: false)

        #expect(events == [.movedSupportFolder, .renamedDatabase])
        #expect(read("\(newSupport)/tokenjar.sqlite") == "db")
        #expect(!exists("\(newSupport)/tokenjar.sqlite-wal") && !exists("\(newSupport)/tokenjar.sqlite-shm"))
    }

    @Test func movesTheConfigFolder() throws {
        defer { home.remove() }
        try home.write(".config/headroom/config.json", "shared")
        try home.write(".config/headroom/config.local.json", "local")

        let events = LegacyMigration.run(paths: paths, legacyAppIsRunning: false)

        #expect(events == [.movedConfigFolder])
        #expect(!exists(".config/headroom"))
        #expect(read(".config/tokenjar/config.json") == "shared")
        #expect(read(".config/tokenjar/config.local.json") == "local")
    }

    @Test func honorsXDGConfigHome() throws {
        defer { home.remove() }
        try home.write("xdg/headroom/config.json", "shared")
        let paths = AppPaths(home: home.url, environment: ["XDG_CONFIG_HOME": home.url.appending(path: "xdg").path])

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [.movedConfigFolder])
        #expect(read("xdg/tokenjar/config.json") == "shared")
        #expect(!exists("xdg/headroom"))
    }

    /// `stow --no-folding`: a real folder whose config.json is a relative link into the dotfiles repo. The folder keeps
    /// its depth, so the link still resolves after the move.
    @Test func aRelativeStowLinkInsideTheConfigFolderStillResolves() throws {
        defer { home.remove() }
        try home.write("dotfiles/headroom/.config/headroom/config.json", "from the repo")
        try home.makeDirectory(".config/headroom")
        let link = "../../dotfiles/headroom/.config/headroom/config.json"
        try FileManager.default.createSymbolicLink(atPath: home.url.appending(path: ".config/headroom/config.json").path, withDestinationPath: link)

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [.movedConfigFolder])

        #expect(linkDestination(".config/tokenjar/config.json") == link)
        #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == "from the repo")
        #expect(read("dotfiles/headroom/.config/headroom/config.json") == "from the repo")
    }

    /// Folded stow: the config folder itself is a relative link. The link moves, never the folder it points to.
    @Test func aConfigFolderThatIsARelativeLinkMovesAsALink() throws {
        defer { home.remove() }
        try home.write("dotfiles/headroom/.config/headroom/config.json", "from the repo")
        try home.makeDirectory(".config")
        let link = "../dotfiles/headroom/.config/headroom"
        try FileManager.default.createSymbolicLink(atPath: home.url.appending(path: ".config/headroom").path, withDestinationPath: link)

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [.movedConfigFolder])

        #expect(linkDestination(".config/tokenjar") == link)
        #expect(!exists(".config/headroom"))
        #expect(try String(contentsOf: paths.configFile, encoding: .utf8) == "from the repo")
        #expect(read("dotfiles/headroom/.config/headroom/config.json") == "from the repo")
    }

    @Test func whenBothNamesExistNothingChanges() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "old db")
        try home.makeDirectory(newSupport)
        try home.write(".config/headroom/config.json", "old config")
        try home.write(".config/tokenjar/config.json", "new config")

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [])

        #expect(read("\(oldSupport)/headroom.sqlite") == "old db")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.url.appending(path: newSupport).path).isEmpty)
        #expect(read(".config/headroom/config.json") == "old config")
        #expect(read(".config/tokenjar/config.json") == "new config")
    }

    /// `--probe` run before the first launch leaves only this behind, and it must not keep Headroom's history from moving.
    @Test func aSupportFolderHoldingOnlyTheEmptyProbeFolderStillMoves() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try paths.createProbeDirectory()

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [.movedSupportFolder, .renamedDatabase])

        #expect(!exists(oldSupport))
        #expect(read("\(newSupport)/tokenjar.sqlite") == "db")
    }

    @Test func aProbeFolderWithAnythingInItStillCountsAsTokenjarsOwn() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try home.write("\(newSupport)/probe/kept", "kept")

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [])

        #expect(read("\(newSupport)/probe/kept") == "kept")
        #expect(read("\(oldSupport)/headroom.sqlite") == "db")
    }

    /// A dangling stow link at the new path is still the user's, so it counts as existing.
    @Test func aDanglingLinkAtTheNewConfigPathIsLeftAlone() throws {
        defer { home.remove() }
        try home.write(".config/headroom/config.json", "old config")
        try FileManager.default.createSymbolicLink(atPath: home.url.appending(path: ".config/tokenjar").path, withDestinationPath: "../dotfiles/gone")

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [])

        #expect(read(".config/headroom/config.json") == "old config")
        #expect(linkDestination(".config/tokenjar") == "../dotfiles/gone")
    }

    @Test func nothingMovesWhileTheOldAppRuns() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try home.write(".config/headroom/config.json", "config")

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: true) == [.skippedWhileLegacyAppRuns])

        #expect(read("\(oldSupport)/headroom.sqlite") == "db")
        #expect(read(".config/headroom/config.json") == "config")
        #expect(!exists(newSupport))
        #expect(!exists(".config/tokenjar"))
    }

    @Test func aHeadroomFolderWhoseTokenjarNameIsFreeIsLeftToMove() throws {
        defer { home.remove() }
        #expect(!LegacyMigration.hasDataToMove(paths: paths))

        try home.write(".config/headroom/config.json", "old config")
        #expect(LegacyMigration.hasDataToMove(paths: paths))
        try home.write(".config/tokenjar/config.json", "new config")
        #expect(!LegacyMigration.hasDataToMove(paths: paths))

        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try paths.createProbeDirectory()
        #expect(LegacyMigration.hasDataToMove(paths: paths))
        try home.write("\(newSupport)/alert-state.json", "alerts")
        #expect(!LegacyMigration.hasDataToMove(paths: paths))
    }

    @Test func aDatabaseStillUnderItsOldNameIsLeftToMove() throws {
        defer { home.remove() }
        try home.write("\(newSupport)/headroom.sqlite", "db")
        #expect(LegacyMigration.hasDataToMove(paths: paths))

        try home.write("\(newSupport)/tokenjar.sqlite-wal", "wal")
        #expect(!LegacyMigration.hasDataToMove(paths: paths))
    }

    @Test func withoutHeadroomFoldersNothingIsCreated() throws {
        defer { home.remove() }

        #expect(LegacyMigration.run(paths: paths, legacyAppIsRunning: false) == [])

        #expect(!exists(newSupport))
        #expect(!exists(".config/tokenjar"))
    }

    @Test func aFolderThatCannotMoveIsReportedAndTheOtherStillMoves() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try home.write(".config/headroom/config.json", "config")
        let parent = home.url.appending(path: "Library/Application Support").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }

        let events = LegacyMigration.run(paths: paths, legacyAppIsRunning: false)

        #expect(events.count == 2)
        #expect(events.first.map { if case .failed = $0 { true } else { false } } == true)
        #expect(events.last == .movedConfigFolder)
        #expect(read("\(oldSupport)/headroom.sqlite") == "db")
        #expect(!exists(newSupport))
    }

    /// SQLite pairs the database with its -wal by name, and the -wal holds transactions not yet in the database, so a
    /// rename that cannot finish puts the files it already renamed back.
    @Test func aDatabaseThatCannotBeRenamedWholeKeepsItsOldNames() throws {
        defer { home.remove() }
        try home.write("\(oldSupport)/headroom.sqlite", "db")
        try home.write("\(oldSupport)/headroom.sqlite-wal", "wal")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: home.url.appending(path: "\(oldSupport)/headroom.sqlite-wal").path)
        defer {
            for folder in [oldSupport, newSupport] {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: home.url.appending(path: "\(folder)/headroom.sqlite-wal").path)
            }
        }

        let events = LegacyMigration.run(paths: paths, legacyAppIsRunning: false)

        #expect(events.count == 2)
        #expect(events.first == .movedSupportFolder)
        #expect(events.last.map { if case .failed = $0 { true } else { false } } == true)
        #expect(read("\(newSupport)/headroom.sqlite") == "db")
        #expect(read("\(newSupport)/headroom.sqlite-wal") == "wal")
        #expect(!exists("\(newSupport)/tokenjar.sqlite"))
    }
}
