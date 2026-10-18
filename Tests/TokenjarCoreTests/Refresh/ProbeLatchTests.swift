import Foundation
import Testing
@testable import TokenjarCore

struct ProbeLatchTests {
    @Test func onlyAModelTurnErrorLatches() {
        #expect(ProbeLatch.CLI(modelTurn: .unsupported(ClaudeUsageFetcher.modelTurnMessage)) == .claude)
        #expect(ProbeLatch.CLI(modelTurn: .unsupported(AntigravityUsageFetcher.modelTurnMessage)) == .agy)
        #expect(ProbeLatch.CLI(modelTurn: .unsupported("Update agy to 1.1.11 or later")) == nil)
        #expect(ProbeLatch.CLI(modelTurn: .timeout) == nil)
    }

    @Test func anUpdatedBinaryReleasesTheLatch() throws {
        let home = TempHome()
        let binary = try makeExecutable(home, "bin/claude")
        let before = try #require(ProbeLatch.fingerprint(ofBinaryAt: binary))
        #expect(ProbeLatch.fingerprint(ofBinaryAt: binary) == before)
        #expect(!before.contains(home.url.path))

        var latch = ProbeLatch()
        latch.latch("work", cli: .claude, binary: before)
        let releasedForSameBinary = latch.releaseAll { _ in before }
        #expect(!releasedForSameBinary)
        #expect(latch.isLatched("work"))

        try makeExecutable(home, "bin/claude", contents: "#!/bin/sh\n# 2.2\nexit 1\n")
        let releasedForNewBinary = latch.releaseAll { _ in ProbeLatch.fingerprint(ofBinaryAt: binary) }
        #expect(releasedForNewBinary)
        #expect(!latch.isLatched("work"))
    }

    @Test func eachLatchFollowsItsOwnCLI() {
        var latch = ProbeLatch()
        latch.latch("work", cli: .claude, binary: "claude-1")
        latch.latch("google", cli: .agy, binary: "agy-1")

        let releasedForSameBinaries = latch.releaseAll { $0 == .claude ? "claude-1" : "agy-1" }
        #expect(!releasedForSameBinaries)

        let releasedForNewAgy = latch.releaseAll { $0 == .claude ? "claude-1" : "agy-2" }
        #expect(releasedForNewAgy)
        #expect(latch.cli(of: "work") == .claude)
        #expect(!latch.isLatched("google"))
    }

    /// probe-latch.json from before agy could latch has no `cli`; those entries were all claude's.
    @Test func aFileFromBeforeAgyLatchesReadsAsClaude() throws {
        let data = Data(#"{"entries":{"work":{"binary":"abc"}}}"#.utf8)
        var latch = try JSONDecoder().decode(ProbeLatch.self, from: data)

        #expect(latch.cli(of: "work") == .claude)
        #expect(!latch.releaseAll { $0 == .claude ? "abc" : nil })
    }

    /// npm keeps `bin/claude` linking to the same file and rewrites that file, so only its target shows the update.
    @Test func anUpdateBehindAnUnchangedLinkIsAnotherBinary() throws {
        let home = TempHome()
        let target = try makeExecutable(home, "lib/claude-code/cli.js")
        let link = home.url.appending(path: "bin/claude")
        try home.makeDirectory("bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = ProbeLatch.fingerprint(ofBinaryAt: link)

        try makeExecutable(home, "lib/claude-code/cli.js", contents: "#!/bin/sh\n# 2.2\nexit 1\n")

        #expect(ProbeLatch.fingerprint(ofBinaryAt: link) != before)
    }

    @Test func blocksMatchesOnlyTheSameBinary() {
        var latch = ProbeLatch()
        latch.latch("work", cli: .claude, binary: "claude-1")

        #expect(latch.blocks(cli: .claude, binary: "claude-1"))
        #expect(!latch.blocks(cli: .claude, binary: "claude-2"))
        #expect(!latch.blocks(cli: .claude, binary: nil))
        #expect(!latch.blocks(cli: .agy, binary: "claude-1"))
        #expect(!ProbeLatch().blocks(cli: .claude, binary: "claude-1"))
    }

    @Test func aLatchWithoutAFingerprintBlocks() {
        var latch = ProbeLatch()
        latch.latch("google", cli: .agy, binary: nil)

        #expect(latch.blocks(cli: .agy, binary: "agy-2"))
        #expect(latch.blocks(cli: .agy, binary: nil))
        #expect(!latch.blocks(cli: .claude, binary: "agy-2"))
    }

    @Test func survivesARoundTripThroughJSON() throws {
        var latch = ProbeLatch()
        latch.latch("work", cli: .claude, binary: "abc")
        latch.latch("personal", cli: .agy, binary: nil)
        let decoded = try JSONDecoder().decode(ProbeLatch.self, from: JSONEncoder().encode(latch))
        #expect(decoded == latch)
        #expect(decoded.accountIDs == ["personal", "work"])
        #expect(decoded.cli(of: "personal") == .agy)
    }

    /// Only its size and modification date matter to the fingerprint; it is never run.
    @discardableResult
    private func makeExecutable(_ home: TempHome, _ relative: String, contents: String = "#!/bin/sh\nexit 1\n") throws -> URL {
        try home.write(relative, contents, permissions: 0o755)
        return home.url.appending(path: relative)
    }
}
