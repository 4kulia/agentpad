import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class NavigationLayoutHostTests: XCTestCase {
    func testRailSelectionFocusesOtherPaneAndReturnsToItsOpenEditor() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.makeKeyAndOrderFront(nil)
        let workspace = try XCTUnwrap(store.active), paneA = try XCTUnwrap(workspace.activePane)
        let a = try XCTUnwrap(paneA.activeTab), engineA = try XCTUnwrap(a.engine as? TestEngine)
        let paneB = try XCTUnwrap(store.splitPane(paneA, orientation: .horizontal, in: workspace))
        let b = store.addTab(in: workspace), engineB = try XCTUnwrap(b.engine as? TestEngine)
        try await settle(controller)
        XCTAssertTrue(paneB.activeTab === b)
        XCTAssertTrue(engineB.view.window === window, "The destination is already mounted before navigation")

        for composer in [true, false] {
            store.activateTab(a, in: workspace)
            a.composerActive = composer
            a.searchActive = !composer
            try await settle(controller)
            let editorA = try XCTUnwrap(window.firstResponder as? NSTextView)
            let controlA = editorA.isFieldEditor ? editorA.delegate as? NSView : editorA

            // The host must not preserve an editor from a different pane,
            // even when navigation did not first move focus into the rail.
            store.activateTab(b, in: workspace)
            controller.paneHost.renderNow()
            XCTAssertTrue(window.firstResponder === engineB.view)
            try await settle(controller)
            XCTAssertTrue(window.firstResponder === engineB.view)

            store.openWorkspaceList()
            try await settle(controller)
            XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: a.id)))
            try await settle(controller)
            XCTAssertTrue(window.firstResponder === editorA, "Selecting a pane must restore its surviving editor")
            if editorA.isFieldEditor { XCTAssertTrue(editorA.delegate as? NSView === controlA) }
            XCTAssertEqual(workspace.activePaneId, paneA.id)

            store.openWorkspaceList()
            try await settle(controller)
            XCTAssertTrue(store.navigationReturnResponder === controlA)
            XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: b.id)))
            if !editorA.isFieldEditor {
                XCTAssertFalse(window.firstResponder === editorA, "Selecting another tab must not restore the source composer")
            }
            try await settle(controller)
            XCTAssertEqual(workspace.activePaneId, paneB.id)
            XCTAssertTrue(window.firstResponder === engineB.view, "Selecting B with an editor open in A must focus B")

            b.composerActive = composer
            b.searchActive = !composer
            try await settle(controller)
            let editorB = try XCTUnwrap(window.firstResponder as? NSTextView)
            let controlB = editorB.isFieldEditor ? editorB.delegate as? NSView : editorB
            for (tab, editor, control) in [(a, editorA, controlA), (b, editorB, controlB)] {
                store.openWorkspaceList()
                try await settle(controller)
                XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
                try await settle(controller)
                XCTAssertTrue(workspace.activeSession === tab)
                XCTAssertTrue(window.firstResponder === editor, "Only the destination's editor may reclaim focus")
                if editor.isFieldEditor { XCTAssertTrue(editor.delegate as? NSView === control) }
            }
            b.composerActive = false
            b.searchActive = false
            try await settle(controller)
            XCTAssertTrue(engineA.sentInputs.isEmpty)
            XCTAssertTrue(engineA.pastedTexts.isEmpty)
            XCTAssertTrue(engineB.sentInputs.isEmpty)
            XCTAssertTrue(engineB.pastedTexts.isEmpty)
        }
    }

    func testRailSelectionBetweenTabsFocusesDestinationComposerAndSearch() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        let workspace = try XCTUnwrap(store.active), a = try XCTUnwrap(workspace.activeSession)
        let b = store.addTab(in: workspace)
        for composer in [true, false] {
            for (tab, title) in [(a, "A"), (b, "B")] {
                tab.composerDraft = "Draft \(title)"
                tab.searchNeedle = "Search \(title)"
                tab.composerActive = composer
                tab.searchActive = !composer
            }
            try await settle(controller)
            for tab in [a, b] {
                store.openWorkspaceList()
                try await settle(controller)
                XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
                try await settle(controller)
                XCTAssertTrue(workspace.activeSession === tab)
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                XCTAssertEqual(editor.string, composer ? tab.composerDraft : tab.searchNeedle)
                XCTAssertFalse(editor.string.isEmpty, "Focus must leave the rail's search field")
            }
        }
    }

    func testRailSelectionRestoresSameTabComposerAndSearchFocus() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        let workspace = try XCTUnwrap(store.active), tab = try XCTUnwrap(workspace.activeSession)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        try await settle(controller)
        for composer in [true, false] {
            tab.composerActive = composer
            tab.searchActive = !composer
            try await settle(controller)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            let control = editor.isFieldEditor ? editor.delegate as? NSView : editor
            store.openWorkspaceList()
            try await settle(controller)
            XCTAssertTrue(store.navigationReturnResponder === control)
            XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
            try await settle(controller)
            XCTAssertTrue(window.firstResponder === editor, "The open editor must regain focus even when selection does not change")
            if editor.isFieldEditor { XCTAssertTrue(editor.delegate as? NSView === control) }
            XCTAssertTrue(engine.sentInputs.isEmpty)
            XCTAssertTrue(engine.pastedTexts.isEmpty)
            if composer {
                store.addWorkspace()
                try await settle(controller)
                store.openWorkspaceList()
                try await settle(controller)
                XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
                try await settle(controller)
                XCTAssertTrue(window.firstResponder === editor, "Changing workspaces must use the same overlay-aware activation path")
            }
        }
        tab.searchActive = false
        try await settle(controller)
        window.makeFirstResponder(engine.view)
        store.openWorkspaceList()
        try await settle(controller)
        XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
        try await settle(controller)
        XCTAssertTrue(window.firstResponder === engine.view, "Ordinary terminal activation still restores focus")

        store.openWorkspaceList()
        try await settle(controller)
        tab.composerActive = true
        try await settle(controller)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(store.navigationReturnResponder === engine.view)
        XCTAssertTrue(store.activateRailDestination(.init(workspaceID: workspace.id, sessionID: tab.id)))
        try await settle(controller)
        XCTAssertTrue(window.firstResponder === editor, "A saved terminal responder must yield to an editor opened during navigation")
    }

    func testRailRefreshNeverReclaimsTerminalFocusAfterEscapeOrRowRemoval() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        let tab = try XCTUnwrap(store.active?.activeSession)
        let engine = try XCTUnwrap(tab.engine as? TestEngine)
        store.renameWorkspace(try XCTUnwrap(store.active), to: "Rail focus fixture")
        engine.emitTitle("Tracked terminal")
        try await settle(controller)
        for collapse in [true, false] {
            window.makeFirstResponder(engine.view)
            store.openWorkspaceList()
            store.navigationPresentation.query = tab.title
            try await settle(controller)
            let matches = WorkspaceRailSearch.matches(store.workspaceRailEntries(), query: store.navigationPresentation.query)
            XCTAssertEqual(WorkspaceRailSearch.destinations(matches).map(\.sessionID), [tab.id], "The focused row must be a tab that disappears on collapse")
            let search = window.firstResponder
            let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
            window.sendEvent(down)
            try await settle(controller)
            XCTAssertFalse(window.firstResponder === search, "Explicit arrow navigation must focus the tab row")
            if collapse { XCTAssertTrue(store.handleNavigationEscape()) }
            else { window.makeFirstResponder(engine.view) }
            try await settle(controller)
            XCTAssertTrue(window.firstResponder === engine.view)
            engine.emitTitle(collapse ? "Renamed terminal" : "No longer matches")
            try await settle(controller)
            XCTAssertTrue(window.firstResponder === engine.view, "Refreshing a stale rail selection must not move keyboard focus")
        }
    }

    private func settle(_ controller: AgentPadWindowController) async throws {
        try await Task.sleep(for: .milliseconds(150))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.paneHost.renderNow()
    }

    func testNativePanelAndPaneHostSurviveAllVisibilityCombinations() async throws {
        let scope = TeamServiceTestScope()
        defer { scope.close() }
        let store = makeTestStore(), controller = AgentPadWindowController(windowId: UUID(), store: store)
        defer { controller.close(); store.terminate() }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.makeKeyAndOrderFront(nil)
        store.renameWorkspace(store.active!, to: "Cedar")
        store.active?.activeSession?.customTitle = "Build and test"
        let second = store.addWorkspace(); store.renameWorkspace(second, to: "API services")
        store.active?.activeSession?.customTitle = "Release logs"
        let content = try XCTUnwrap(window.contentView)
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded(); controller.paneHost.renderNow()
        }
        func findPanel(_ view: NSView) -> NSHostingView<SidebarView>? {
            if let panel = view as? NSHostingView<SidebarView> { return panel }
            for child in view.subviews { if let panel = findPanel(child) { return panel } }
            return nil
        }
        try await settle()
        let panel = try XCTUnwrap(findPanel(content))
        let host = controller.paneHost
        for rail in [true, false] {
            for visible in [true, false] {
                store.leftNavigation = .init(railVisible: rail, panelVisible: visible)
                try await settle()
                XCTAssertTrue(findPanel(content) === panel)
                XCTAssertTrue(controller.paneHost === host)
                XCTAssertEqual(panel.isHidden, !visible)
                let frame = host.convert(host.bounds, to: content)
                XCTAssertEqual(frame.minX, (rail ? 58 : 0) + (visible ? 268 : 0), accuracy: 1)
                XCTAssertEqual(frame.maxX, content.bounds.maxX, accuracy: 1)
                XCTAssertFalse(store.isSidebarResizing)
            }
        }
        store.leftNavigation = .init()
        store.openWorkspaceList()
        try await settle()
        XCTAssertEqual(host.convert(host.bounds, to: content).minX, 252 + 268, accuracy: 1)
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_RAIL_SNAPSHOTS"] {
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("rail-expanded.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        store.navigationPresentation.query = "Build and test"
        try await settle()
        XCTAssertEqual(store.activeWorkspaceId, second.id, "Filtering must not activate a result")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await settle()
        XCTAssertEqual(store.activeWorkspaceId, store.workspaces.first?.id)
        XCTAssertEqual(store.active?.activeSession?.customTitle, "Build and test")
        XCTAssertEqual(store.navigationPresentation.list, .closed)
        store.requestRenameActiveWorkspace()
        try await settle()
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, "Cedar", "The inline editor, not search, owns focus")
        store.handleNavigationEscape()
        store.closeNavigation()
        window.setContentSize(NSSize(width: 800, height: 720))
        try await settle()
        store.toggleNavigationPanel()
        try await settle()
        XCTAssertEqual(panel.frame.width, 216, accuracy: 1)
        XCTAssertEqual(host.convert(host.bounds, to: content).minX, 58, accuracy: 1)
        XCTAssertEqual(store.sidebarDisplayWidth, 268)
        XCTAssertEqual(store.leftNavigation.panelVisible, true)
    }
}
