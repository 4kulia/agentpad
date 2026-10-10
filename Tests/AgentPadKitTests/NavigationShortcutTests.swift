import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class NavigationShortcutTests: XCTestCase {
    func testInstalledMenuHasUniqueBindingsAndPreservesTerminalCommands() throws {
        let app = NSApplication.shared
        let original = app.mainMenu, windows = app.windowsMenu, help = app.helpMenu
        defer { app.mainMenu = original; app.windowsMenu = windows; app.helpMenu = help }
        let disk = AppPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let delegate = AppDelegate(appPersistence: disk, agentProfiles: AgentProfileStore())
        delegate.installMainMenu()
        func flatten(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
        }
        let items = flatten(try XCTUnwrap(app.mainMenu)).filter { !$0.keyEquivalent.isEmpty }
        func command(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ selector: String) {
            let matches = items.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
            XCTAssertEqual(matches.count, 1, "Conflicting menu binding for \(key) / \(modifiers)")
            XCTAssertEqual(matches.first?.action.map(NSStringFromSelector), selector)
        }
        command("r", [.control, .command], "handleNavigationCommand:")
        command("s", [.control, .command], "handleNavigationCommand:")
        command("0", [.option, .command], "handleNavigationCommand:")
        command("k", [.command], "handleClearScrollback")
        command("p", [.command], "handleQuickOpen")
        command("r", [.command], "handleRenameTab")
        command("r", [.shift, .command], "handleRenameWorkspace")
        command("0", [.command], "handleResetFontSize")
        for digit in 1...9 {
            command("\(digit)", [.command], "handleSwitchTab:")
            command("\(digit)", [.option, .command], "handleSwitchWorkspace:")
        }
        XCTAssertFalse(items.contains { $0.keyEquivalentModifierMask == [.control, .option] }, "Do not claim VoiceOver navigation")
    }

    func testPaletteIncludesNavigationEvenWhenBothSurfacesAreHidden() {
        let snapshot = PaletteIndex.snapshot(controllers: [], model: .shared)
        let commands = snapshot.items.compactMap { item -> LeftNavigationCommand? in
            if case .navigation(let command) = item.kind { return command }
            return nil
        }
        XCTAssertEqual(Set(commands), Set(LeftNavigationCommand.allCases))
        let store = makeTestStore(); defer { store.terminate() }
        store.leftNavigation = .init(railVisible: false, panelVisible: false)
        store.performNavigationCommand(.workspaces)
        XCTAssertEqual(store.navigationPresentation.list, .peek)
        XCTAssertFalse(store.leftNavigation.railVisible)
        store.performNavigationCommand(.chat)
        XCTAssertTrue(store.leftNavigation.panelVisible)
        XCTAssertFalse(store.leftNavigation.railVisible)
    }
}
