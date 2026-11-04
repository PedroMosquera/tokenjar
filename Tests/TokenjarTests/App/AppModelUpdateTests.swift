import Foundation
import Testing
@testable import Tokenjar
import TokenjarCore

private nonisolated final class UpdateAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    var total: Int { lock.withLock { asked } }

    func fetch() async throws -> ReleaseInfo {
        lock.withLock { asked += 1 }
        return UpdateFetcher.releaseInfo(for: AppVersion("0.3.0")!)!
    }
}

@MainActor
struct AppModelUpdateTests {
    private func automaticChecker(_ asks: UpdateAsks) -> UpdateChecker {
        let checker = UpdateChecker(defaults: MemoryDefaults(), installed: AppVersion("0.3.0"), fetch: { try await asks.fetch() })
        checker.mode = .automatic
        return checker
    }

    @Test func anOfflineModelHoldsTheUpdateCheckUntilItIsBackOnline() async throws {
        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig(accounts: []))
        let clock = TestClock()
        let model = AppModel(paths: home.paths, clock: { clock.now }, network: FakeNetworkStatus())
        model.loadState()
        let asks = UpdateAsks()
        model.updates = automaticChecker(asks)

        model.networkPathChanged(.unusable)
        clock.advance(NetworkWatch.offlineSettle)
        model.settleNetwork()
        #expect(model.checkForUpdatesIfDue() == nil)
        #expect(asks.total == 0)

        model.networkPathChanged(.usable)
        clock.advance(NetworkWatch.onlineSettle)
        await model.settleNetwork()?.value
        await model.checkForUpdatesIfDue()?.value
        #expect(asks.total == 1)
    }

    @Test func previewsAndReadOnlyModelsNeverAskForUpdates() async throws {
        let asks = UpdateAsks()
        let preview = AppModel(paths: .preview)
        preview.previewMode = true
        preview.updates = automaticChecker(asks)
        #expect(preview.checkForUpdatesIfDue() == nil)

        let home = try ModelHome()
        defer { home.remove() }
        try home.writeConfig(AppConfig(accounts: []))
        let readOnly = AppModel(paths: home.paths)
        readOnly.loadReadOnly(store: InMemoryUsageStore())
        readOnly.updates = automaticChecker(asks)
        #expect(readOnly.checkForUpdatesIfDue() == nil)
        #expect(asks.total == 0)
    }
}
