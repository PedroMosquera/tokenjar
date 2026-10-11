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
}
