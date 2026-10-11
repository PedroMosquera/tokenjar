import AppKit
import TokenjarCore

/// Draws the status item images. Template images let the menu bar pick black or white for the current
/// wallpaper; an image only becomes non-template when it has to carry a severity color.
enum StatusGlyph {
    static let glyphSide: CGFloat = 18
    static let barsHeight: CGFloat = 18
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2
    /// The failure dot overhangs the glyph's top right corner by half its width.
    static let dotDiameter: CGFloat = 5

    struct Bar: Equatable {
        /// 0...1 of the tightest window; nil when the account has no data.
        var fraction: Double?
        var severity: Severity
        var dimmed: Bool
    }

    /// The image for worst and icon modes. The default, the cooldown slot, is filled to `fraction` (0...1) of the
    /// tightest window. Every other choice is a static glyph that still takes the tint, fade and dot, so warnings show.
    static func image(_ icon: MenuBarIcon, fraction: Double, tint: NSColor?, alpha: CGFloat, dot: Bool, description: String = "Tokenjar") -> NSImage {
        compose(glyph(icon) ?? slot(fraction), description: description, tint: tint, alpha: alpha, dot: dot)
    }

    /// Shown when nothing is configured or no account has reported yet. The slot shows its base pose faint, so it
    /// never reads as a real level.
    static func neutral(_ icon: MenuBarIcon, dot: Bool, description: String = "Tokenjar") -> NSImage {
        compose(glyph(icon) ?? neutralSlot, description: description, tint: nil, alpha: 1, dot: dot)
    }

    /// The template glyph of a choice other than the app mark; nil for the app mark or a file that did not load, so
    /// the menu bar falls back to the slot instead of going blank.
    static func glyph(_ icon: MenuBarIcon) -> NSImage? {
        if let cached = glyphs[icon] { return cached }
        let image: NSImage?
        switch icon.source {
        case .slot: return nil
        case .mark(let name): image = ProviderLogo.resourceURL("Marks/\(name).svg").flatMap(NSImage.init(contentsOf:))
        case .logo(let name): image = ProviderLogo.logoURL(name).flatMap(NSImage.init(contentsOf:))
        case .symbol(let name): image = symbol(name)
        }
        image?.isTemplate = true
        glyphs[icon] = image
        return image
    }

    /// A choice's glyph centered on a square canvas, so the picker's rows line up whatever the glyph's width.
    static func picture(_ icon: MenuBarIcon) -> NSImage {
        let base = glyph(icon) ?? slot(basePose)
        let size = fitted(base.size)
        let image = NSImage(size: NSSize(width: glyphSide, height: glyphSide), flipped: false) { rect in
            base.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = icon.title
        return image
    }

    private static var glyphs: [MenuBarIcon: NSImage] = [:]

    /// Semibold matches the marks' 1.5 pt strokes. A symbol too big for the glyph box is requested smaller rather
    /// than scaled down by `fitted`, which would thin its strokes (brain is 23 pt wide at 15 pt).
    private static func symbol(_ name: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var pointSize: CGFloat = 15
        while let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)) {
            if max(image.size.width, image.size.height) <= glyphSide || pointSize <= 9 { return image }
            pointSize -= 0.5
        }
        return nil
    }

    /// The pose the app icon and the SVG source are drawn in.
    static let basePose = 0.8

    /// The slot as a template, drawn on the 18 x 18 grid of its SVG source. A wedge sweeps clockwise from 12 o'clock
    /// like a game's cooldown wipe and is clipped to the inner square, so its corners fill as the sweep passes them.
    static func slot(_ fraction: Double, wedgeAlpha: CGFloat = 1) -> NSImage {
        let side = glyphSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let deviceScale = NSGraphicsContext.current.map { abs($0.cgContext.userSpaceToDeviceSpaceTransform.a) } ?? 2
            let grid = NSAffineTransform()
            grid.scale(by: side / 18)
            grid.concat()
            NSColor.black.set()
            // The SVG source has the frame at 2...16 with a 1.6 stroke and the square at 4.3...13.7. At 2x these keep its
            // proportions and the 1.5 gap with every straight edge on a whole pixel. At 1x a 1.5 stroke would straddle
            // a pixel and draw a soft gray column, so the frame is one whole pixel with the same outer edge and corner,
            // which matches the menu bar text's 1x stroke and keeps the gap to the square.
            let frame = deviceScale < 1.5
                ? NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 15), xRadius: 3, yRadius: 3)
                : NSBezierPath(roundedRect: NSRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), xRadius: 2.75, yRadius: 2.75)
            frame.lineWidth = deviceScale < 1.5 ? 1 : 1.5
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

    static func bars(_ bars: [Bar], description: String) -> NSImage {
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
        image.accessibilityDescription = description
        return image
    }

    /// Fits `base` into a `glyphSide` box, optionally tinted, faded, and badged with a dot that knocks a ring
    /// out of the glyph so it reads as separate even in a one-color template image. The dot's room is kept with or
    /// without it, so the status item, and every item to its left, stays put when a check fails or recovers.
    private static func compose(_ base: NSImage, description: String, tint: NSColor?, alpha: CGFloat, dot: Bool) -> NSImage {
        let glyph = fitted(base.size)
        let size = NSSize(width: glyph.width + dotDiameter / 2, height: max(glyphSide, glyph.height))
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

    /// Glyphs keep their own size, so a full-bleed 16 pt logo is not blown up past the slot; only larger ones shrink.
    private static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: glyphSide, height: glyphSide) }
        let scale = min(1, glyphSide / max(size.width, size.height))
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
