import AppKit
import HeadroomCore

/// Draws the status item images. Template images let the menu bar pick black or white for the current
/// wallpaper; an image only becomes non-template when it has to carry a severity color.
enum StatusGlyph {
    static let glyphSide: CGFloat = 16
    static let barsHeight: CGFloat = 18
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2

    struct Bar: Equatable {
        /// 0...1 of the tightest window; nil when the account has no data.
        var fraction: Double?
        var severity: Severity
        var dimmed: Bool
    }

    /// The provider logo, or an SF Symbol stand-in when the SVG is not bundled.
    static func provider(_ provider: ProviderID, tint: NSColor?, alpha: CGFloat, dot: Bool) -> NSImage {
        let base = ProviderLogo.image(provider, template: true) ?? symbol(fallbackSymbol(provider), description: provider.displayName)
        return compose(base, description: provider.displayName, tint: tint, alpha: alpha, dot: dot)
    }

    /// Shown when nothing is configured or no account has reported yet.
    static func neutral(dot: Bool) -> NSImage {
        compose(symbol("gauge.with.dots.needle.33percent", description: "Headroom"), description: "Headroom", tint: nil, alpha: 1, dot: dot)
    }

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

    private static func fallbackSymbol(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "sparkle"
        case .codex: "terminal"
        case .opencodeGo, .opencodeZen: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "arrow.up.circle"
        }
    }

    private static func symbol(_ name: String, description: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: glyphSide, height: glyphSide))
    }

    /// Fits `base` into a 16 pt box, optionally tinted, faded, and badged with a dot that knocks a ring
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
