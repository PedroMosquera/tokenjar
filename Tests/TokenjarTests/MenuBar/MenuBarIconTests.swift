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
            let size = try #require(NSImage(contentsOf: url)?.size)
            #expect(size.height == 18 && size.width <= 18)
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

    /// A mark's canvas hugs its ink, so the gap to the % and the error dot match the slot's instead of floating off.
    @Test(arguments: MenuBarIcon.allCases.filter { $0.rawValue.hasPrefix("mark:") })
    func marksSitCenteredWithNoMoreSideRoomThanTheSlot(_ icon: MenuBarIcon) throws {
        let glyph = try #require(StatusGlyph.glyph(icon))
        let ink = try #require(inkBounds(glyph))
        #expect(ink.minX <= 1, "left room \(ink.minX)")
        #expect(glyph.size.width - ink.maxX <= 1, "right room \(glyph.size.width - ink.maxX)")
        #expect(abs(ink.midY - glyph.size.height / 2) <= 0.5, "ink center \(ink.midY) of \(glyph.size.height)")
    }

    /// Scaling a symbol down after the fact thins its strokes, so each is requested at a size that already fits.
    @Test(arguments: MenuBarIcon.allCases.filter { $0.rawValue.hasPrefix("symbol:") })
    func symbolsAreDrawnAtASizeThatFits(_ icon: MenuBarIcon) throws {
        let size = try #require(StatusGlyph.glyph(icon)?.size)
        #expect(max(size.width, size.height) <= StatusGlyph.glyphSide, "\(size)")
    }

    /// The gauge's dial is a plain ring, so its edge on the middle row is one stroke wide, like the slot's frame.
    @Test func symbolStrokesAreAsHeavyAsTheSlotFrame() {
        let slot = firstInkRun(StatusGlyph.image(.app, fraction: 0, tint: nil, alpha: 1, dot: false))
        let gauge = firstInkRun(StatusGlyph.image(.symbolGauge, fraction: 0, tint: nil, alpha: 1, dot: false))
        #expect(abs(gauge - slot) < 0.15, "gauge \(gauge) pt, slot \(slot) pt")
    }

    @Test func onlyModesThatShowTheIconUseTheIconSetting() {
        #expect(MenuBarMode.allCases.filter(\.usesIcon) == [.worst, .icon])
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

@MainActor
private func render(_ image: NSImage, scale: CGFloat = 8) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The box around every pixel with real ink, in points from the top left.
@MainActor
private func inkBounds(_ image: NSImage) -> NSRect? {
    let scale: CGFloat = 8
    guard let rep = render(image, scale: scale) else { return nil }
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX + 1 - minX) / scale, height: CGFloat(maxY + 1 - minY) / scale)
}

/// Width in points of the first stretch of ink on the image's middle row, weighting each pixel by its coverage.
@MainActor
private func firstInkRun(_ image: NSImage) -> CGFloat {
    let scale: CGFloat = 8
    guard let rep = render(image, scale: scale) else { return -1 }
    let row = rep.pixelsHigh / 2
    var x = 0
    while x < rep.pixelsWide, (rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) < 0.05 { x += 1 }
    var width: CGFloat = 0
    while x < rep.pixelsWide, let alpha = rep.colorAt(x: x, y: row)?.alphaComponent, alpha >= 0.05 {
        width += alpha
        x += 1
    }
    return width / scale
}
