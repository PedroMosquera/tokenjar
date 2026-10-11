import AppKit
import SwiftUI
import Testing
@testable import Tokenjar

@MainActor
struct MainMenuTests {
    private final class SettingsOpener: NSObject {
        @objc func openSettings(_ sender: Any?) {}
    }

    private struct Entry: Equatable, CustomStringConvertible {
        var title: String
        var key: String
        var modifiers: NSEvent.ModifierFlags
        var action: String?

        init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, action: String?) {
            self.title = title
            self.key = key
            self.modifiers = key.isEmpty ? [] : modifiers
            self.action = action
        }

        init(_ item: NSMenuItem) {
            title = item.isSeparatorItem ? "-" : item.title
            key = item.keyEquivalent
            modifiers = item.keyEquivalent.isEmpty ? [] : item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            action = item.action.map(NSStringFromSelector)
        }

        static let separator = Entry("-", action: nil)

        var description: String { "\(title) \(key) \(modifiers.rawValue) \(action ?? "nil")" }
    }

    private let opener = SettingsOpener()

    private func menu() -> NSMenu {
        MainMenu.make(appName: "Tokenjar", settingsTarget: opener, settingsAction: #selector(SettingsOpener.openSettings(_:)))
    }

    private func entries(_ title: String) throws -> [Entry] {
        let submenu = try #require(menu().items.first { $0.submenu?.title == title }?.submenu, "no \(title) menu")
        return submenu.items.map(Entry.init)
    }

    /// A SwiftUI App needs a scene, and each scene can open a window of its own: Settings opened an empty one for
    /// Command-comma and during render runs.
    @Test func theAppIsNotASwiftUIApp() {
        let entry: Any.Type = TokenjarApp.self
        #expect(!(entry is any App.Type))
    }

    @Test func theMenuBarHasTheAppEditAndWindowMenus() {
        #expect(menu().items.compactMap(\.submenu?.title) == ["Tokenjar", "Edit", "Window"])
    }

    /// A built menu does nothing until the app holds it: no menu bar, so no Command-comma, Command-C, -V, -A or -W.
    @Test func installingGivesTheAppTheMenuBarAndItsWindowMenu() throws {
        let app = NSApplication.shared
        let saved = (app.mainMenu, app.windowsMenu)
        defer { (app.mainMenu, app.windowsMenu) = saved }
        app.mainMenu = nil
        app.windowsMenu = nil

        MainMenu.install(in: app, appName: "Tokenjar", settingsTarget: opener, settingsAction: #selector(SettingsOpener.openSettings(_:)))

        let bar = try #require(app.mainMenu)
        #expect(bar.items.compactMap(\.submenu?.title) == ["Tokenjar", "Edit", "Window"])
        #expect(bar.items.first?.submenu?.items.first { $0.keyEquivalent == "," }?.target === opener)
        let window = try #require(app.windowsMenu)
        #expect(window === bar.items.first { $0.submenu?.title == "Window" }?.submenu)
    }

    @Test func theAppMenuOpensTokenjarSettingsWithCommandComma() throws {
        #expect(try entries("Tokenjar") == [
            Entry("About Tokenjar", action: "orderFrontStandardAboutPanel:"),
            .separator,
            Entry("Settings\u{2026}", ",", action: "openSettings:"),
            .separator,
            Entry("Hide Tokenjar", "h", action: "hide:"),
            Entry("Hide Others", "h", [.command, .option], action: "hideOtherApplications:"),
            Entry("Show All", action: "unhideAllApplications:"),
            .separator,
            Entry("Quit Tokenjar", "q", action: "terminate:"),
        ])
        let settings = try #require(menu().items.first?.submenu?.items.first { $0.title == "Settings\u{2026}" })
        #expect(settings.target === opener)
    }

    /// Text fields take Command-C, -V and -A only through these items: without them a pasted API key needs the context menu.
    @Test func theEditMenuSendsTheStandardTextActionsDownTheResponderChain() throws {
        #expect(try entries("Edit") == [
            Entry("Undo", "z", action: "undo:"),
            Entry("Redo", "z", [.command, .shift], action: "redo:"),
            .separator,
            Entry("Cut", "x", action: "cut:"),
            Entry("Copy", "c", action: "copy:"),
            Entry("Paste", "v", action: "paste:"),
            Entry("Select All", "a", action: "selectAll:"),
        ])
        let edit = try #require(menu().items.first { $0.submenu?.title == "Edit" }?.submenu)
        #expect(edit.items.allSatisfy { $0.target == nil })
    }

    @Test func theWindowMenuMinimizesAndClosesTheKeyWindow() throws {
        #expect(try entries("Window") == [
            Entry("Minimize", "m", action: "performMiniaturize:"),
            Entry("Close", "w", action: "performClose:"),
        ])
    }
}
