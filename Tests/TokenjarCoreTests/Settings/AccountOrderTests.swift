import Foundation
import Testing
@testable import TokenjarCore

struct AccountOrderTests {
    private let work = AccountConfig(id: "claude", provider: .claude, label: "Work")
    private let copilot = AccountConfig(id: "copilot", provider: .copilot, label: "Default")
    private let personal = AccountConfig(id: "claude-2", provider: .claude, label: "Personal")
    private let devin = AccountConfig(id: "devin", provider: .devin, label: "Default")

    private var accounts: [AccountConfig] { [work, copilot, personal, devin] }

    @Test func manualKeepsTheUsersOrder() {
        #expect(AccountOrder.manual.sorted(accounts, fullness: ["copilot": 90]).map(\.id) == ["claude", "copilot", "claude-2", "devin"])
    }

    /// Providers come in the order of their first account, and each provider's accounts keep the user's order.
    @Test func byProviderGroupsWithoutReorderingWithinAProvider() {
        #expect(AccountOrder.byProvider.sorted(accounts, fullness: [:]).map(\.id) == ["claude", "claude-2", "copilot", "devin"])
    }

    /// An account with nothing to measure goes last, and ties keep the user's order so cards do not swap on every refresh.
    @Test func tightestFirstPutsTheFullestOnTop() {
        let fullness = ["claude": 16, "copilot": 0.04, "claude-2": 76]
        #expect(AccountOrder.tightestFirst.sorted(accounts, fullness: fullness).map(\.id) == ["claude-2", "claude", "copilot", "devin"])
        #expect(AccountOrder.tightestFirst.sorted([copilot, work], fullness: ["claude": 5, "copilot": 5]).map(\.id) == ["copilot", "claude"])
    }
}
