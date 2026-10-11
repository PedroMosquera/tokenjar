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
        return state(isBundledApp: true, status: SMAppService.mainApp.status)
    }

    /// Inside a bundle, a status macOS does not know yet (a fresh build at a new path reports .notFound) is off, so the
    /// toggle still calls register() and a real refusal reaches the user as an error instead of a dead switch.
    static func state(isBundledApp: Bool, status: SMAppService.Status) -> State {
        guard isBundledApp else { return .unavailable }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
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
