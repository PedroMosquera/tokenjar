import Testing
import UserNotifications
@testable import Tokenjar

struct NotificationPermissionTests {
    /// Provisional is what a default config gets at launch; Settings must be able to tell it from banners.
    @Test func provisionalIsQuietNotBanners() {
        #expect(NotificationPermission(.provisional) == .quiet)
        #expect(NotificationPermission(.authorized) == .banners)
        #expect(NotificationPermission(.denied) == .denied)
        #expect(NotificationPermission(.notDetermined) == .notDetermined)
    }
}
