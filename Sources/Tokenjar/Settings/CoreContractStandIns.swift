import Foundation
import TokenjarCore

// Stand-ins for APIs the core-app branch adds (FetchError.attention, ProviderID.reportsWindows, the public
// AccountDiscovery lookups and AppModel.canEditConfig), under the same names so Settings compiles against them now.
// Delete this file when merging after core-app: its definitions then collide with the real ones.

extension FetchError {
    enum Attention: Equatable {
        case calm, transient, actionable
    }

    var attention: Attention {
        switch self {
        case .noSubscription: .calm
        case .network, .timeout, .rateLimited: .transient
        case .cliNotFound, .notSignedIn, .unauthorized, .parse, .unsupported: .actionable
        }
    }
}

extension ProviderID {
    var reportsWindows: Bool {
        switch self {
        case .opencodeZen, .devin: false
        case .claude, .codex, .opencodeGo, .antigravity, .copilot: true
        }
    }
}

extension AccountDiscovery {
    static func location(of account: AccountConfig, paths: AppPaths, environment: [String: String]) -> URL? {
        switch account.provider {
        case .claude: account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".claude")
        case .codex: account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".codex")
        case .copilot: account.profileDir.map(paths.expand) ?? paths.home.appending(path: ".config/gh")
        case .opencodeGo, .opencodeZen:
            switch account.credential {
            case .file(let path, _): paths.expand(path)
            case .keychain: nil
            case nil: openCodeAuthFile(paths: paths, environment: environment)
            }
        case .antigravity, .devin: nil
        }
    }

    static func openCodeAuthFile(paths: AppPaths, environment: [String: String]) -> URL {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appending(path: "opencode/auth.json")
        }
        return paths.home.appending(path: ".local/share/opencode/auth.json")
    }
}

extension AppModel {
    /// core-app defines it as !configLoadFailed, which is private to AppModel; its messages stand in for it here.
    var canEditConfig: Bool {
        guard let problem = configError else { return true }
        return !["Could not read", "config.json is missing", "Headroom"].contains { problem.hasPrefix($0) }
    }
}
