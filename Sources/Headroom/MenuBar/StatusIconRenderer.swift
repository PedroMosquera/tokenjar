import AppKit
import HeadroomCore

struct RenderedStatusIcon {
    var image: NSImage?
    var title: String = ""
    var attributedTitle = NSAttributedString()
    var toolTip: String?
}

enum StatusIconRenderer {
    static func render(_ state: MenuBarState) -> RenderedStatusIcon {
        let worst = state.worst
        let text = worst?.tightest.map { Format.percent($0.usedPercent) } ?? "–"
        return RenderedStatusIcon(
            image: worst.flatMap { ProviderLogo.image($0.provider, template: true) },
            title: text,
            attributedTitle: NSAttributedString(string: text),
            toolTip: "Headroom"
        )
    }
}
