import Foundation
import ServiceManagement

/// The only code that touches login item registration. `set` is called from the General toggle and nowhere else,
/// so builds, tests and snapshot renders never register anything.
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        /// Not running as an installed .app (a SwiftPM build folder binary cannot be a login item).
        case unavailable
    }

    private static var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var state: State {
        guard isBundledApp else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    static func set(_ enabled: Bool) throws -> State {
        guard isBundledApp else { return .unavailable }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return state
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
