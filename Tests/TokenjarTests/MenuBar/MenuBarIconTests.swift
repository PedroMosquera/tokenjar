import AppKit
import Testing
@testable import Tokenjar
import TokenjarCore

/// PNG bytes of `image` as drawn, so two images can be compared pixel for pixel.
@MainActor
func pixels(_ image: NSImage?) -> Data? {
    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

@MainActor
struct MenuBarIconTests {
    @Test(arguments: MenuBarIcon.allCases)
    func everyChoiceResolvesToAGlyph(_ icon: MenuBarIcon) throws {
        switch icon.source {
        case .slot:
            #expect(StatusGlyph.glyph(icon) == nil)
        case .mark(let name):
            let url = try #require(ProviderLogo.resourceURL("Marks/\(name).svg"), "missing Resources/Marks/\(name).svg")
            #expect(NSImage(contentsOf: url)?.size == NSSize(width: 18, height: 18))
            #expect(StatusGlyph.glyph(icon) != nil)
        case .logo(let name):
            #expect(ProviderLogo.logoURL(name) != nil, "missing Resources/Logos/\(name).svg")
            #expect(StatusGlyph.glyph(icon) != nil)
        case .symbol(let name):
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no SF Symbol \(name) on this macOS")
            #expect(StatusGlyph.glyph(icon) != nil)
        }
        let image = StatusGlyph.image(icon, fraction: 0.5, tint: nil, alpha: 1, dot: false)
        #expect(image.isTemplate)
        #expect(image.size.height == StatusGlyph.glyphSide)
        #expect(image.size.width <= StatusGlyph.glyphSide)
    }

    @Test func onlyTheAppMarkShowsTheLevel() {
        for icon in MenuBarIcon.allCases {
            let low = pixels(StatusGlyph.image(icon, fraction: 0.1, tint: nil, alpha: 1, dot: false))
            let high = pixels(StatusGlyph.image(icon, fraction: 0.9, tint: nil, alpha: 1, dot: false))
            #expect((low == high) == (icon != .app), "\(icon.rawValue)")
        }
    }

    @Test func pickerGroupsListEveryChoiceOnce() {
        #expect(MenuBarIcon.Group.allCases.map(\.title) == ["App mark", "More marks", "Provider logos", "Symbols"])
        #expect(MenuBarIcon.Group.allCases.flatMap(\.icons) == MenuBarIcon.allCases)
        #expect(MenuBarIcon.Group.app.icons == [.app])
        #expect(MenuBarIcon.Group.marks.icons.map(\.title) == ["Mana", "Taper", "Tally", "Burnrate", "Genio"])
        #expect(MenuBarIcon.Group.logos.icons.map(\.title) == ["Claude", "ChatGPT / OpenAI", "Gemini", "GitHub Copilot", "OpenCode", "Windsurf / Devin"])
        #expect(MenuBarIcon.Group.symbols.icons.map(\.source) == [.symbol("sparkles"), .symbol("brain"), .symbol("cpu"), .symbol("gauge.with.needle")])
    }

    @Test func modeDescriptionsNameTheChosenIcon() {
        #expect(MenuBarMode.worst.summary(for: .app) == "The slot, filled to the used share of the account with the least room left, and that used %.")
        #expect(MenuBarMode.worst.summary(for: .logoClaude) == "The Claude logo and the used % of the account with the least room left.")
        #expect(MenuBarMode.icon.summary(for: .app) == "The slot only, filled to the tightest used share and tinted amber or red when an account runs low.")
        #expect(MenuBarMode.icon.summary(for: .symbolBrain) == "The Brain symbol only, tinted amber or red when an account runs low.")
        #expect(MenuBarMode.icon.summary(for: .markMana) == "The Mana mark only, tinted amber or red when an account runs low.")
        #expect(MenuBarMode.bars.summary(for: .logoClaude) == "One thin bar per account shown in the menu bar, in place of the icon.")
    }
}
