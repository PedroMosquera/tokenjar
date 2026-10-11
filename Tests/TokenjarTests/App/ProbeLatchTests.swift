import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

@MainActor
struct ProbeLatchTests {
    @Test func onlyAModelTurnErrorLatches() {
        #expect(ProbeLatch.CLI(modelTurn: .unsupported(ClaudeUsageFetcher.modelTurnMessage)) == .claude)
        #expect(ProbeLatch.CLI(modelTurn: .unsupported(AntigravityUsageFetcher.modelTurnMessage)) == .agy)
        #expect(ProbeLatch.CLI(modelTurn: .unsupported("Update agy to 1.1.11 or later")) == nil)
        #expect(ProbeLatch.CLI(modelTurn: .timeout) == nil)
    }

    @Test func anUpdatedBinaryReleasesTheLatch() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let binary = try home.makeExecutable("bin/claude")
        let before = try #require(ProbeLatch.fingerprint(ofBinaryAt: binary))
        #expect(ProbeLatch.fingerprint(ofBinaryAt: binary) == before)
        #expect(!before.contains(home.url.path))

        var latch = ProbeLatch()
        latch.latch("work", cli: .claude, binary: before)
        let releasedForSameBinary = latch.releaseAll { _ in before }
        #expect(!releasedForSameBinary)
        #expect(latch.isLatched("work"))

        try home.makeExecutable("bin/claude", contents: "#!/bin/sh\n# 2.2\nexit 1\n")
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
        let home = try ModelHome()
        defer { home.remove() }
        let target = try home.makeExecutable("lib/claude-code/cli.js")
        let link = home.url.appending(path: "bin/claude")
        try home.makeDirectory("bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let before = ProbeLatch.fingerprint(ofBinaryAt: link)

        try home.makeExecutable("lib/claude-code/cli.js", contents: "#!/bin/sh\n# 2.2\nexit 1\n")

        #expect(ProbeLatch.fingerprint(ofBinaryAt: link) != before)
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
}
