import AppKit
import TokenjarCore

/// Draws the status item images. Template images let the menu bar pick black or white for the current
/// wallpaper; an image only becomes non-template when it has to carry a severity color.
enum StatusGlyph {
    static let glyphSide: CGFloat = 18
    static let barsHeight: CGFloat = 18
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2

    struct Bar: Equatable {
        /// 0...1 of the tightest window; nil when the account has no data.
        var fraction: Double?
        var severity: Severity
        var dimmed: Bool
    }

    /// Tokenjar's own mark, the cooldown slot, filled to `fraction` (0...1) of the tightest window. The menu bar uses
    /// it instead of a provider logo, which would be mistaken for that provider's own app sitting next to it.
    static func image(fraction: Double, tint: NSColor?, alpha: CGFloat, dot: Bool) -> NSImage {
        compose(slot(fraction), description: "Tokenjar", tint: tint, alpha: alpha, dot: dot)
    }

    /// Shown when nothing is configured or no account has reported yet: the base pose drawn faint, so it never
    /// reads as a real level.
    static func neutral(dot: Bool) -> NSImage {
        compose(neutralSlot, description: "Tokenjar", tint: nil, alpha: 1, dot: dot)
    }

    /// The pose the app icon and the SVG source are drawn in.
    static let basePose = 0.8

    /// The slot as a template, drawn on the 18 x 18 grid of its SVG source. A wedge sweeps clockwise from 12 o'clock
    /// like a game's cooldown wipe and is clipped to the inner square, so its corners fill as the sweep passes them.
    static func slot(_ fraction: Double, wedgeAlpha: CGFloat = 1) -> NSImage {
        let side = glyphSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let grid = NSAffineTransform()
            grid.scale(by: side / 18)
            grid.concat()
            NSColor.black.set()
            // The SVG source has the frame at 2...16 with a 1.6 stroke and the square at 4.3...13.7. These keep its
            // proportions and the 1.5 gap, but land every straight edge on a whole pixel at 2x, so the frame stays crisp.
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 2.75, yRadius: 2.75)
            frame.lineWidth = 1.5
            frame.stroke()
            let square = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 10, height: 10), xRadius: 1, yRadius: 1)
            NSColor.black.withAlphaComponent(wedgeAlpha).setFill()
            if fraction >= 1 {
                square.fill()
            } else if fraction > 0 {
                let center = NSPoint(x: 9, y: 9)
                let wedge = NSBezierPath()
                wedge.move(to: center)
                wedge.appendArc(withCenter: center, radius: 9, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                wedge.close()
                square.addClip()
                wedge.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let neutralSlot = slot(basePose, wedgeAlpha: 0.35)

    static func bars(_ bars: [Bar]) -> NSImage {
        let count = CGFloat(max(bars.count, 1))
        let size = NSSize(width: count * barWidth + (count - 1) * barGap, height: barsHeight)
        let colored = bars.contains { $0.severity > .ok }
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, bar) in bars.enumerated() {
                let track = NSRect(x: CGFloat(index) * (barWidth + barGap), y: 0, width: barWidth, height: barsHeight)
                let shape = NSBezierPath(roundedRect: track, xRadius: barWidth / 2, yRadius: barWidth / 2)
                let ink: NSColor = colored && bar.severity > .ok ? bar.severity.nsColor : (colored ? .labelColor : .black)
                let alpha: CGFloat = bar.dimmed ? 0.5 : 1
                ink.withAlphaComponent(0.28 * alpha).setFill()
                shape.fill()
                guard let fraction = bar.fraction, fraction > 0 else { continue }
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                ink.withAlphaComponent(alpha).setFill()
                let height = max(barWidth / 2, barsHeight * min(fraction, 1))
                NSRect(x: track.minX, y: 0, width: barWidth, height: height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = !colored
        // Non-template colors resolve against the menu bar's appearance at draw time, so never cache a rendering.
        if colored { image.cacheMode = .never }
        image.accessibilityDescription = "Usage bars"
        return image
    }

    /// Fits `base` into a `glyphSide` box, optionally tinted, faded, and badged with a dot that knocks a ring
    /// out of the glyph so it reads as separate even in a one-color template image.
    private static func compose(_ base: NSImage, description: String, tint: NSColor?, alpha: CGFloat, dot: Bool) -> NSImage {
        let glyph = fitted(base.size)
        let dotDiameter: CGFloat = 5
        let size = NSSize(width: glyph.width + (dot ? dotDiameter / 2 : 0), height: max(glyphSide, glyph.height))
        let glyphRect = NSRect(x: 0, y: (size.height - glyph.height) / 2, width: glyph.width, height: glyph.height)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            base.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
            if let tint {
                tint.setFill()
                glyphRect.fill(using: .sourceAtop)
            }
            if dot {
                let dotRect = NSRect(x: size.width - dotDiameter, y: size.height - dotDiameter, width: dotDiameter, height: dotDiameter)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                (tint ?? .black).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = description
        return image
    }

    private static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: glyphSide, height: glyphSide) }
        let scale = glyphSide / max(size.width, size.height)
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
