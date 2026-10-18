#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import TokenjarCore

struct LogoAssetTests {
    private var logos: URL {
        TestPaths.repository.appending(path: "Resources/Logos")
    }

    /// docs/logos.md: every mark is normalized to 16 x 16 pt, the menu bar glyph height.
    @Test(arguments: ProviderID.allCases)
    func everyProviderHasALoadableLogoAtMenuBarSize(_ provider: ProviderID) throws {
        let url = logos.appending(path: "\(provider.logoName).svg")
        let image = try #require(NSImage(contentsOf: url), "missing or unreadable \(url.lastPathComponent)")
        #expect(image.size == NSSize(width: 16, height: 16))
    }
}
#endif
