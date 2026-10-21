import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class PopupFocusIsolationTests: XCTestCase {
    final class TerminalInputView: NSView {
        var input = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { input += event.characters ?? "" }
    }

    @MainActor private final class TabMenuTarget: NSObject {
        let store: WorkspaceStore
        var calls = 0
        init(_ store: WorkspaceStore) { self.store = store }
        @objc func nextTab() {
            calls += 1
            if let workspace = store.active { store.cycleTab(in: workspace, direction: 1) }
        }
    }

    @MainActor final class Host {
        let scope = TeamServiceTestScope()
        let store: WorkspaceStore
        let controller: AgentPadWindowController
        let window: NSWindow
        let terminals: [TerminalInputView]

        init(simulateKey: Bool = false) throws {
            var views: [TerminalInputView] = []
            let store = WorkspaceStore(persistence: InMemoryPersistence(), sessionNames: .testing,
                engineFactory: {
                    let view = TerminalInputView(); views.append(view)
                    return TestEngine(view: view)
                }, optionsProvider: { _ in nil }, resumeProvider: { true },
                claudeProjectsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("agentpad-no-claude-sessions"))
            _ = store.addTab(in: try XCTUnwrap(store.active), template: .terminal)
            self.store = store
            terminals = views
            let testWindow = simulateKey ? SearchTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false) : nil
            testWindow?.isReleasedWhenClosed = false
            let controller = AgentPadWindowController(windowId: UUID(), store: store, adopting: testWindow)
            self.controller = controller
            let window = try XCTUnwrap(controller.window)
            self.window = window
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.makeKeyAndOrderFront(nil)
        }

        func close() { controller.close(); store.terminate(); scope.close() }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            controller.paneHost.renderNow()
        }

        func dialog() throws -> NSView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).first {
                $0.accessibilityIdentifier() == "popup-dialog"
            })
        }

        func containsPopupFocus() throws -> Bool {
            let dialog = try dialog()
            guard let responder = window.firstResponder as? NSView else { return false }
            if responder.isDescendant(of: dialog) { return true }
            return ((responder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: dialog) == true
        }

        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }

    }

    func testControlTabCannotNavigateOrTypeIntoTerminalUnderSettingsOrProfile() async throws {
        let host = try Host(); defer { host.close() }
        let originalMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = originalMenu }
        let target = TabMenuTarget(host.store)
        let menu = NSMenu(), viewMenu = NSMenu(title: "View")
        let root = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        root.submenu = viewMenu; menu.addItem(NSMenuItem()); menu.addItem(root)
        let next = NSMenuItem(title: "Next Tab", action: #selector(TabMenuTarget.nextTab), keyEquivalent: "\t")
        next.target = target; next.keyEquivalentModifierMask = .control
        viewMenu.addItem(next); NSApp.mainMenu = menu
        try await host.settle()
        try host.key("\t", code: 48, modifiers: .control)
        try await host.settle()
        XCTAssertEqual(target.calls, 1, "Positive control: native Ctrl+Tab routes through the menu")

        for route in [ToolRoute.settings, .agentProfile(UUID())] {
            let opener = try XCTUnwrap(host.store.active?.activeSession?.engine.view as? TerminalInputView)
            XCTAssertTrue(host.window.makeFirstResponder(opener))
            let beforeInput = host.terminals.map(\.input)
            _ = host.store.openToolTab(route)
            try await host.settle()
            XCTAssertTrue(try host.containsPopupFocus())
            let active = host.store.active?.activeSession?.id
            let previousCalls = target.calls
            try host.key("\t", code: 48, modifiers: .control)
            try await host.settle()
            try host.key("x", code: 7)
            XCTAssertEqual(target.calls, previousCalls, "Popup must consume Ctrl+Tab before menu routing")
            XCTAssertEqual(host.store.active?.activeSession?.id, active)
            XCTAssertTrue(try host.containsPopupFocus())
            XCTAssertEqual(host.terminals.map(\.input), beforeInput, "Typing must never reach a terminal under a popup")
            host.store.popups.dismiss(reason: .dismiss)
            try await host.settle()
            XCTAssertTrue(host.window.firstResponder === opener, "Closing a terminal-opened popup restores that terminal")
            let input = opener.input
            try host.key("z", code: 6)
            XCTAssertEqual(opener.input, input + "z")
        }
    }

    func testDisappearingSearchOpenerRestoresUnchangedActiveTerminal() async throws {
        _ = SupportTabs.shared
        let settings = AgentPadSettingsModel.shared, previousPill = settings.showSearchPill
        settings.showSearchPill = false
        defer { settings.showSearchPill = previousPill }
        let host = try Host(simulateKey: true); defer { host.close() }
        try await host.settle()
        let active = try XCTUnwrap(host.store.active?.activeSession)
        let target = try XCTUnwrap(active.engine.view as? TerminalInputView)
        XCTAssertTrue(host.window.makeFirstResponder(target))
        XCTAssertNil(host.store.search.fieldFocus.field, "The pill is hidden before Command-P")
        // The installed Command-P action calls this same toggle; ContentView
        // mounts the temporary field only for the explicit search request.
        host.store.search.toggle()
        try await host.settle()
        XCTAssertTrue(host.store.search.fieldFocused)
        XCTAssertNotNil(host.store.search.fieldFocus.field)

        let router = TabRouter.shared
        let previousAdmit = router.admit, previousStores = router.stores, previousHost = router.ensureHost
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu, previousHelp = NSApp.helpMenu
        router.admit = nil; router.stores = { [host.store] }; router.ensureHost = { host.store }
        defer {
            router.admit = previousAdmit; router.stores = previousStores; router.ensureHost = previousHost
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows; NSApp.helpMenu = previousHelp
        }
        let delegate = AppDelegate(appPersistence: AppPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-windows.json")),
            agentProfiles: host.store.agentProfiles)
        delegate.installMainMenu()
        let comma = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: comma) == true)
        try await host.settle()
        XCTAssertNil(host.store.search.fieldFocus.field, "Dismissal unmounts the temporary search field")
        XCTAssertTrue(try host.containsPopupFocus())
        try host.key("x", code: 7)
        XCTAssertEqual(target.input, "")
        XCTAssertEqual(host.terminals.map(\.input), ["", ""])
        try host.key("\u{1b}", code: 53)
        try await host.settle()
        XCTAssertFalse(host.store.popups.isPresented)
        XCTAssertTrue(host.store.active?.activeSession === active, "Fallback must work without a tab switch")
        XCTAssertTrue(host.window.firstResponder === target, "Missing opener must focus active content")
        try host.key("z", code: 6)
        XCTAssertEqual(target.input, "z", "Typing after Esc must reach active content")
        XCTAssertNil(host.store.search.fieldFocus.field, "Fallback must not remount the hidden pill")
    }

    func testTabReconcileAndExplicitContentFocusCannotStealPopupResponder() async throws {
        let host = try Host(); defer { host.close() }
        try await host.settle()
        let workspace = try XCTUnwrap(host.store.active)
        // Both surfaces must already be mounted: an unvisited tab makes
        // syncFocus return at its target.window guard and cannot reproduce.
        host.store.cycleTab(in: workspace, direction: 1)
        try await host.settle()
        host.store.cycleTab(in: workspace, direction: 1)
        try await host.settle()
        XCTAssertTrue(host.terminals.allSatisfy { $0.window === host.window })
        _ = host.store.openToolTab(.settings)
        try await host.settle()
        XCTAssertTrue(try host.containsPopupFocus())
        host.store.cycleTab(in: workspace, direction: 1)
        host.controller.paneHost.renderNow()
        XCTAssertTrue(try host.containsPopupFocus(), "Reconciliation must leave the first responder inside the popup")
        let dialog = try host.dialog()
        XCTAssertTrue(host.window.makeFirstResponder(dialog))
        host.controller.paneHost.restoreFocus()
        XCTAssertTrue(try host.containsPopupFocus(), "Focus Content must not override an open popup")
        try host.key("x", code: 7)
        XCTAssertEqual(host.terminals.map(\.input), ["", ""])
    }

    // Installed-menu and dynamic Window-menu checks live in
    // AgentPadNoModalsSelfCheck.popupNavigationMenus(): command-line XCTest
    // cannot own NSApp.keyWindow, which is the native menu-validation input.
}
