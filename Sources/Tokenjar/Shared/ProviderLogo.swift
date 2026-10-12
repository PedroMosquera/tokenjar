import AppKit
import SwiftUI
import TokenjarCore

/// Loads provider marks from Contents/Resources/Logos (installed app) or the repo's Resources/Logos (swift run).
/// Never uses Bundle.module: its lookup traps once the app runs anywhere other than where it was built.
enum ProviderLogo {
    private static var cache: [String: NSImage] = [:]

    static func image(_ provider: ProviderID, template: Bool) -> NSImage? {
        let key = "\(provider.logoName)-\(template)"
        if let cached = cache[key] { return cached }
        guard let url = logoURL(provider.logoName), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        cache[key] = image
        return image
    }

    static func logoURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appending(path: "Logos/\(name).svg"), fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Logos/\(name).svg")
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Resources/<name> from the app bundle, falling back to the repo checkout during development.
    static func resourceURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appending(path: name), fm.fileExists(atPath: bundled.path) { return bundled }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/\(name)")
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }
}

/// Decorative for VoiceOver: every place that shows a logo shows the provider's name beside it.
struct ProviderLogoView: View {
    var provider: ProviderID
    var size: CGFloat = 16
    /// Logos ship as single-color glyphs; nil tints them with the provider's brand color.
    var tint: Color?

    var body: some View {
        logo.accessibilityHidden(true)
    }

    @ViewBuilder
    private var logo: some View {
        if let image = ProviderLogo.image(provider, template: true) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint ?? provider.brandColor)
                .frame(width: size, height: size)
        } else {
            Text(String(provider.displayName.prefix(1)))
                .font(.system(size: size * 0.6, weight: .bold))
                .frame(width: size, height: size)
                .background(Circle().fill(.quaternary))
        }
    }
}

extension ProviderID {
    /// Brand hues from docs/logos.md. Monochrome marks (OpenAI, OpenCode) follow the text color so they read in dark mode.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .antigravity: Color(red: 0x8E / 255, green: 0x75 / 255, blue: 0xB2 / 255)
        case .codex, .opencodeGo, .opencodeZen, .copilot, .devin: .primary
        }
    }
}
