import AppKit
import Testing
@testable import Tokenjar

@MainActor
struct StatusItemMenuTests {
    private final class Delegate: NSObject, StatusItemMenuTarget {
        var calls: [String] = []
        func refreshNow(_ sender: Any?) { calls.append("refresh") }
        func openDashboard(_ sender: Any?) { calls.append("dashboard") }
        func openSettings(_ sender: Any?) { calls.append("settings") }
        func requestQuit(_ sender: Any?) { calls.append("quit") }
        func quitWithoutAsking(_ sender: Any?) { calls.append("quit without asking") }
    }

    private struct Entry: Equatable, CustomStringConvertible {
        enum Target { case delegate, app, none }

        var title: String
        var action: String?
        var target: Target
        var alternate: (modifiers: NSEvent.ModifierFlags, key: String)?

        init(_ title: String, _ action: String?, _ target: Target, alternate: NSEvent.ModifierFlags? = nil) {
            self.title = title
            self.action = action
            self.target = target
            self.alternate = alternate.map { ($0, "") }
        }

        init(_ item: NSMenuItem, delegate: Delegate) {
            title = item.isSeparatorItem ? "-" : item.title
            action = item.action.map(NSStringFromSelector)
            target = item.target === delegate ? .delegate : item.target === NSApplication.shared ? .app : .none
            if item.isAlternate {
                alternate = (item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), item.keyEquivalent)
            }
        }

        static let separator = Entry("-", nil, .none)

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.title == rhs.title && lhs.action == rhs.action && lhs.target == rhs.target
                && lhs.alternate?.modifiers == rhs.alternate?.modifiers && lhs.alternate?.key == rhs.alternate?.key
        }

        var description: String {
            let alternate = alternate.map { " alternate \($0.modifiers.rawValue) \"\($0.key)\"" } ?? ""
            return "\(title) \(action ?? "nil") \(target)\(alternate)"
        }
    }

    private let delegate = Delegate()

    private func entries(hasAccounts: Bool) -> [Entry] {
        StatusItemMenu.make(hasAccounts: hasAccounts, target: delegate).items.map { Entry($0, delegate: delegate) }
    }

    /// Option turns "Quit Tokenjar..." into "Quit Tokenjar", which quits without asking.
    @Test func withAccountsTheMenuRefreshesOpensTheWindowsAndQuits() {
        #expect(entries(hasAccounts: true) == [
            Entry("Refresh Now", "refreshNow:", .delegate),
            Entry("Open Dashboard", "openDashboard:", .delegate),
            Entry("Settings\u{2026}", "openSettings:", .delegate),
            .separator,
            Entry("Quit Tokenjar\u{2026}", "requestQuit:", .delegate),
            Entry("Quit Tokenjar", "quitWithoutAsking:", .delegate, alternate: .option),
        ])
    }

    /// Without accounts a refresh has nothing to check, so the item is not there at all rather than shown dimmed.
    @Test func withoutAccountsRefreshNowIsLeftOut() {
        #expect(entries(hasAccounts: false) == [
            Entry("Open Dashboard", "openDashboard:", .delegate),
            Entry("Settings\u{2026}", "openSettings:", .delegate),
            .separator,
            Entry("Quit Tokenjar\u{2026}", "requestQuit:", .delegate),
            Entry("Quit Tokenjar", "quitWithoutAsking:", .delegate, alternate: .option),
        ])
    }

    /// Built fresh for each open, so nothing validates or updates it later, and nothing in it is ever dimmed.
    @Test(arguments: [true, false])
    func everyItemIsEnabledWithNoKeyOrImage(hasAccounts: Bool) {
        let menu = StatusItemMenu.make(hasAccounts: hasAccounts, target: delegate)
        #expect(!menu.autoenablesItems)
        #expect(menu.delegate == nil)
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.isEnabled && !$0.isHidden })
        #expect(items.allSatisfy { $0.keyEquivalent.isEmpty && $0.image == nil })
    }

    /// An item aimed anywhere but the test's delegate is recorded, not sent, since a terminate: that got through would
    /// end the run with exit code 0.
    @Test func eachItemReachesItsTarget() {
        let menu = StatusItemMenu.make(hasAccounts: true, target: delegate)
        let refusal = RefusesToQuit()
        refusal.whileInstalled {
            for item in menu.items where !item.isSeparatorItem {
                guard item.target === delegate, let action = item.action else {
                    Issue.record("\(item.title) sends \(String(describing: item.action)) to \(String(describing: item.target))")
                    continue
                }
                NSApplication.shared.sendAction(action, to: item.target, from: item)
            }
        }
        #expect(!refusal.wasAsked)
        #expect(delegate.calls == ["refresh", "dashboard", "settings", "quit", "quit without asking"])
    }
}
