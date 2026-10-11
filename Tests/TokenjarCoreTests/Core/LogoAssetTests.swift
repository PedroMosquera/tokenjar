import AppKit
import Foundation
import Testing
@testable import TokenjarCore

struct LogoAssetTests {
    private var logos: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Logos")
    }

    @Test(arguments: ProviderID.allCases)
    func everyProviderHasALoadableLogo(_ provider: ProviderID) throws {
        let url = logos.appending(path: "\(provider.logoName).svg")
        let image = try #require(NSImage(contentsOf: url), "missing or unreadable \(url.lastPathComponent)")
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    /// Marks for providers still to come (GitHub Copilot, and Windsurf standing in for Devin). Only the menu bar icon
    /// picker draws them so far, at this size.
    @Test(arguments: ["copilot", "windsurf"])
    func logosForProvidersStillToComeLoadAtMenuBarSize(_ name: String) throws {
        let url = logos.appending(path: "\(name).svg")
        let image = try #require(NSImage(contentsOf: url), "missing or unreadable \(url.lastPathComponent)")
        #expect(image.size == NSSize(width: 16, height: 16))
    }
}
