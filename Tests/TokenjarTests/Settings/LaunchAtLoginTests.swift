import ServiceManagement
import Testing
@testable import Tokenjar

/// Only the pure mapping is tested: asking SMAppService for a status or registering would touch this Mac's login items.
struct LaunchAtLoginTests {
    @Test func anInstalledAppThatMacOSDoesNotKnowYetIsOffSoTheToggleCanRegisterIt() {
        #expect(LaunchAtLogin.state(isBundledApp: true, status: .notFound) == .disabled)
        #expect(LaunchAtLogin.state(isBundledApp: true, status: .notRegistered) == .disabled)
    }

    @Test func anInstalledAppReportsWhatMacOSSays() {
        #expect(LaunchAtLogin.state(isBundledApp: true, status: .enabled) == .enabled)
        #expect(LaunchAtLogin.state(isBundledApp: true, status: .requiresApproval) == .requiresApproval)
    }

    @Test func onlyAnUnavailableStateLocksTheToggle() {
        #expect(!LaunchAtLogin.State.unavailable.canChange)
        for state: LaunchAtLogin.State in [.enabled, .disabled, .requiresApproval] {
            #expect(state.canChange)
        }
    }

    @Test func aBuildFolderBinaryIsUnavailableWhateverTheStatus() {
        for status: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .notFound] {
            #expect(LaunchAtLogin.state(isBundledApp: false, status: status) == .unavailable)
        }
    }
}
