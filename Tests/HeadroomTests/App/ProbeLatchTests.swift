import Foundation
import Testing
@testable import Headroom
import HeadroomCore

@MainActor
struct ProbeLatchTests {
    @Test func onlyTheModelTurnErrorLatches() {
        #expect(ProbeLatch.spentTokens(.unsupported(ClaudeUsageFetcher.modelTurnMessage)))
        #expect(!ProbeLatch.spentTokens(.unsupported("agy 1.0 is too old")))
        #expect(!ProbeLatch.spentTokens(.timeout))
    }

    @Test func anUpdatedBinaryReleasesTheLatch() throws {
        let home = try ModelHome()
        defer { home.remove() }
        let binary = try home.makeExecutable("bin/claude")
        let before = try #require(ProbeLatch.fingerprint(ofBinaryAt: binary))
        #expect(ProbeLatch.fingerprint(ofBinaryAt: binary) == before)
        #expect(!before.contains(home.url.path))

        var latch = ProbeLatch()
        latch.latch("work", binary: before)
        let releasedForSameBinary = latch.releaseAll(unlessBinary: before)
        #expect(!releasedForSameBinary)
        #expect(latch.isLatched("work"))

        try home.makeExecutable("bin/claude", contents: "#!/bin/sh\n# 2.2\nexit 1\n")
        let releasedForNewBinary = latch.releaseAll(unlessBinary: ProbeLatch.fingerprint(ofBinaryAt: binary))
        #expect(releasedForNewBinary)
        #expect(!latch.isLatched("work"))
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
        latch.latch("work", binary: "abc")
        latch.latch("personal", binary: nil)
        let decoded = try JSONDecoder().decode(ProbeLatch.self, from: JSONEncoder().encode(latch))
        #expect(decoded == latch)
        #expect(decoded.accountIDs == ["personal", "work"])
    }
}
