import AppKit
import Testing
@testable import Tokenjar

/// Alpha of `image` at a point of the mark's 18 x 18 design grid, measured from the top left like the SVG source.
@MainActor
func glyphAlpha(_ image: NSImage?, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
    guard let image else { return -1 }
    let scale: CGFloat = 8
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return -1 }
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    let unit = StatusGlyph.glyphSide / 18
    let top = (image.size.height - StatusGlyph.glyphSide) / 2
    return rep.colorAt(x: Int(x * unit * scale), y: Int((top + y * unit) * scale))?.alphaComponent ?? -1
}

@MainActor
struct StatusGlyphTests {
    /// Points well inside the inner square, away from its rounded corners.
    private let inside: [(CGFloat, CGFloat)] = [(5.2, 5.2), (9, 5), (12.8, 5.2), (13, 9), (12.8, 12.8), (9, 13), (5.2, 12.8), (5, 9), (9, 9)]

    @Test func theWedgeSweepsClockwiseFromTwelve() {
        let quarter = StatusGlyph.slot(0.25)
        #expect(glyphAlpha(quarter, 11.5, 6.5) > 0.9)
        #expect(glyphAlpha(quarter, 6.5, 6.5) < 0.1)
        #expect(glyphAlpha(quarter, 11.5, 11.5) < 0.1)
        let threeQuarters = StatusGlyph.slot(0.75)
        #expect(glyphAlpha(threeQuarters, 11.5, 11.5) > 0.9)
        #expect(glyphAlpha(threeQuarters, 6.5, 11.5) > 0.9)
        #expect(glyphAlpha(threeQuarters, 6.5, 6.5) < 0.1)
    }

    /// A wedge cut from a circle inside the square would leave the corners empty until the very end.
    @Test func theWedgeReachesTheCornersOfTheSquare() {
        #expect(glyphAlpha(StatusGlyph.slot(0.3), 13.2, 4.8) > 0.9)
    }

    @Test func emptyShowsOnlyTheFrameAndFullFillsTheSquare() {
        let empty = StatusGlyph.slot(0)
        for (x, y) in inside {
            #expect(glyphAlpha(empty, x, y) < 0.1, "empty at \(x), \(y)")
        }
        for full in [StatusGlyph.slot(1), StatusGlyph.slot(1.4)] {
            for (x, y) in inside {
                #expect(glyphAlpha(full, x, y) > 0.9, "full at \(x), \(y)")
            }
            // The gap between the frame and the square stays open, so a full slot still reads as a slot.
            #expect(glyphAlpha(full, 9, 3.3) < 0.1)
        }
        for glyph in [empty, StatusGlyph.slot(1)] {
            #expect(glyphAlpha(glyph, 9, 1.9) > 0.9)
            #expect(glyphAlpha(glyph, 1.9, 9) > 0.9)
        }
    }

    @Test func neutralDrawsTheBasePoseFaint() {
        let neutral = StatusGlyph.neutral(.app, dot: false)
        #expect(neutral.isTemplate)
        #expect(glyphAlpha(neutral, 9, 1.9) > 0.9)
        #expect(abs(glyphAlpha(neutral, 11.5, 11.5) - 0.35) < 0.05)
        #expect(abs(glyphAlpha(neutral, 5, 11) - 0.35) < 0.05)
        // The slice the 80 % pose leaves open, between ten and twelve o'clock.
        #expect(glyphAlpha(neutral, 7, 6) < 0.05)
    }

    @Test func theMarkIsSizedForTheMenuBar() {
        #expect(StatusGlyph.slot(0.5).size == NSSize(width: 18, height: 18))
    }
}
