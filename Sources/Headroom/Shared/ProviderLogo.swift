import AppKit
import SwiftUI
import HeadroomCore

/// Loads provider marks from Contents/Resources/Logos (installed app) or the repo's Resources/Logos (swift run).
/// Never uses Bundle.module: its lookup traps when the bundle is moved off the build machine.
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

struct ProviderLogoView: View {
    var provider: ProviderID
    var size: CGFloat = 16
    var template = false

    var body: some View {
        if let image = ProviderLogo.image(provider, template: template) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Text(String(provider.displayName.prefix(1)))
                .font(.system(size: size * 0.6, weight: .bold))
                .frame(width: size, height: size)
                .background(Circle().fill(.quaternary))
        }
    }
}
