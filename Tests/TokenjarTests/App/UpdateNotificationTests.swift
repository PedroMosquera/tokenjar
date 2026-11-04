import Testing
import TokenjarCore
@testable import Tokenjar

struct UpdateNotificationTests {
    @Test func updateNotificationText() throws {
        let installed = try #require(AppVersion("0.3.0"))
        let latest = try #require(AppVersion("0.4.0"))
        let content = NotificationManager.updateContent(installed: installed, latest: latest)
        #expect(content.title == "Tokenjar 0.4.0 is available")
        #expect(content.body == "You have 0.3.0. Open Settings > About to see what changed and how to update.")
        #expect(content.userInfo["route"] as? String == "about")
        #expect(content.categoryIdentifier.isEmpty)
        #expect(content.threadIdentifier == "tokenjar-update")
    }
}
