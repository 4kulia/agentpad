import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class WorkspaceRailCollapseTests: XCTestCase {
    func testIndividualTransitionsKeepSelectionAndNewWorkspacesStartExpanded() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let first = try XCTUnwrap(store.active), tab = try XCTUnwrap(first.activeSession)
        let second = store.addWorkspace()
        store.activateWorkspace(first)
        store.openWorkspaceList()
        XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
        store.toggleWorkspaceTabs(second.id)
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [second.id])
        store.setWorkspaceTabsCollapsed(true, workspaceID: second.id)
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [second.id])
        store.setWorkspaceTabsCollapsed(true, workspaceID: UUID())
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [second.id])
        XCTAssertEqual(store.activeWorkspaceId, first.id)
        XCTAssertTrue(first.activeSession === tab)
        XCTAssertEqual(store.navigationPresentation.list, .expanded)
        store.toggleWorkspaceTabs(second.id)
        XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
        store.toggleAllWorkspaceTabs()
        XCTAssertTrue(store.allWorkspaceTabsCollapsed)
        let new = store.addWorkspace()
        XCTAssertFalse(store.leftNavigation.collapsedWorkspaceIDs.contains(new.id))
        XCTAssertFalse(store.allWorkspaceTabsCollapsed)
    }

    func testMixedAndOptionToggleIncludeFilteredOutWorkspacesAndWorktrees() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let first = try XCTUnwrap(store.active)
        store.renameWorkspace(first, to: "Visible")
        let child = store.addWorkspace(); child.worktreeParentId = first.id
        let third = store.addWorkspace()
        store.openWorkspaceList()
        store.navigationPresentation.query = "Visible"
        store.toggleWorkspaceTabs(first.id)
        XCTAssertFalse(store.allWorkspaceTabsCollapsed)
        store.toggleAllWorkspaceTabs()
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [first.id, child.id, third.id])
        XCTAssertTrue(store.allWorkspaceTabsCollapsed)
        store.toggleWorkspaceTabs(first.id, event: try mouseEvent(.leftMouseUp, modifiers: .option))
        XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
        store.toggleWorkspaceTabs(child.id)
        store.toggleWorkspaceTabs(first.id, event: try mouseEvent(.leftMouseDown, modifiers: .option))
        XCTAssertTrue(store.allWorkspaceTabsCollapsed, "Option-click has the same mixed-state rule as the header")
        store.toggleAllWorkspaceTabs()
        XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty)
        XCTAssertEqual(store.navigationPresentation.query, "Visible")
        XCTAssertEqual(store.activeWorkspaceId, third.id)
    }

    func testNonOptionClickActivationsOnlyToggleTheirWorkspace() throws {
        let disk = InMemoryPersistence(), store = makeTestStore(persistence: disk)
        defer { store.terminate() }
        let first = try XCTUnwrap(store.active), second = store.addWorkspace()
        store.renameWorkspace(first, to: "Visible")
        store.renameWorkspace(second, to: "Hidden")
        store.openWorkspaceList()
        store.navigationPresentation.query = "Visible"
        var events: [NSEvent?] = [
            nil, // Accessibility/programmatic activation has no mouse event.
            try mouseEvent(.leftMouseDown),
            try mouseEvent(.leftMouseUp),
            try mouseEvent(.mouseMoved, modifiers: .option),
        ]
        for (type, modifiers) in [(NSEvent.EventType.keyDown, NSEvent.ModifierFlags.option),
                                 (.keyDown, [.control, .option]), (.keyUp, [.control, .option]),
                                 (.flagsChanged, .option)] {
            events.append(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        }
        for event in events {
            store.setWorkspaceTabsCollapsed(true, workspaceID: first.id)
            store.toggleWorkspaceTabs(first.id, event: event)
            XCTAssertTrue(store.leftNavigation.collapsedWorkspaceIDs.isEmpty,
                          "Only the collapsed workspace should expand for \(String(describing: event?.type))")
            store.toggleWorkspaceTabs(first.id, event: event)
            XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [first.id])
            store.flushPersistence()
            XCTAssertEqual(disk.saved?.leftNavigation?.collapsedWorkspaceIDs, [first.id])
            XCTAssertEqual(store.activeWorkspaceId, second.id)
            XCTAssertEqual(store.navigationPresentation.query, "Visible")
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    func testSearchTemporarilyRevealsTabsAndClearRestoresChangesMadeDuringSearch() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active), first = try XCTUnwrap(workspace.activeSession)
        store.renameWorkspace(workspace, to: "Cedar")
        first.renameForTesting("Deploy production")
        let second = store.addTab(in: workspace); second.renameForTesting("Build logs")
        let child = store.addWorkspace(); child.worktreeParentId = workspace.id
        child.customTitle = "Birch"; child.activeSession?.renameForTesting("Child task")
        let entries = store.workspaceRailEntries()
        func matches(_ query: String, parents: Set<UUID> = []) -> [WorkspaceRailSearch.Match] {
            WorkspaceRailSearch.matches(entries, query: query, collapsedParents: parents,
                collapsedWorkspaceIDs: store.leftNavigation.collapsedWorkspaceIDs)
        }
        store.toggleAllWorkspaceTabs()
        XCTAssertEqual(matches("").map(\.tabs), [[], []])
        XCTAssertEqual(matches("").map(\.tabsExpanded), [false, false])
        XCTAssertEqual(WorkspaceRailSearch.destinations(matches("")),
                       [.init(workspaceID: workspace.id), .init(workspaceID: child.id)])
        XCTAssertEqual(matches("  PRODUCTION \n").flatMap(\.tabs).map(\.id), [first.id])
        XCTAssertTrue(try XCTUnwrap(matches("production").first).tabsExpanded)
        XCTAssertEqual(WorkspaceRailSearch.destinations(matches("production")),
                       [.init(workspaceID: workspace.id, sessionID: first.id)])
        XCTAssertEqual(matches("CEDAR").flatMap(\.tabs).map(\.id), [first.id, second.id])
        XCTAssertEqual(matches("Child", parents: [workspace.id]).flatMap(\.tabs).map(\.id), [child.activeSession!.id])
        store.toggleWorkspaceTabs(workspace.id)
        XCTAssertEqual(matches("production").flatMap(\.tabs).map(\.id), [first.id])
        XCTAssertEqual(matches("").flatMap(\.tabs).map(\.id), [first.id, second.id])
        store.toggleAllWorkspaceTabs()
        XCTAssertEqual(matches("production").flatMap(\.tabs).map(\.id), [first.id])
        XCTAssertTrue(matches(" \n ").flatMap(\.tabs).isEmpty)
        XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, [workspace.id, child.id])
    }

    func testPreferencesRoundTripPerWindowAndSurviveNavigationAndSelection() throws {
        let aDisk = InMemoryPersistence(), bDisk = InMemoryPersistence()
        let a = makeTestStore(persistence: aDisk), b = makeTestStore(persistence: bDisk)
        defer { a.terminate(); b.terminate() }
        let first = try XCTUnwrap(a.active), second = a.addWorkspace(), other = try XCTUnwrap(b.active)
        a.toggleWorkspaceTabs(first.id)
        b.toggleWorkspaceTabs(other.id)
        a.openWorkspaceList()
        XCTAssertTrue(a.activateRailDestination(.init(workspaceID: first.id, sessionID: first.activeSession!.id)))
        a.toggleWorkspaceRail(); a.openWorkspaceList()
        XCTAssertEqual(a.navigationPresentation.list, .peek)
        a.closeNavigation(); a.toggleWorkspaceRail(); a.openWorkspaceList()
        a.activateWorkspace(second)
        XCTAssertEqual(a.leftNavigation.collapsedWorkspaceIDs, [first.id])
        XCTAssertEqual(b.leftNavigation.collapsedWorkspaceIDs, [other.id])
        a.flushPersistence(); b.flushPersistence()
        let app = PersistedApp(windows: [
            .init(id: a.windowID, state: try XCTUnwrap(aDisk.saved)),
            .init(id: b.windowID, state: try XCTUnwrap(bDisk.saved))
        ])
        let restored = try JSONDecoder().decode(PersistedApp.self, from: JSONEncoder().encode(app))
        for (saved, expected) in zip(restored.windows, [[first.id], [other.id]]) {
            let store = makeTestStore(persistence: InMemoryPersistence(initial: saved.state))
            defer { store.terminate() }
            XCTAssertEqual(store.leftNavigation.collapsedWorkspaceIDs, Set(expected))
            XCTAssertEqual(store.allSessions.map(\.id), (saved.id == a.windowID ? a : b).allSessions.map(\.id))
        }
        let detached = makeTestStore(); defer { detached.terminate() }
        detached.inheritNavigation(from: a)
        XCTAssertTrue(detached.leftNavigation.collapsedWorkspaceIDs.isEmpty, "Workspace IDs belong to the original window")
    }

    func testMissingOrDamagedCollapsedPreferenceDoesNotLoseWindowState() throws {
        let disk = InMemoryPersistence(), store = makeTestStore(persistence: disk)
        defer { store.terminate() }
        store.flushPersistence()
        let state = try XCTUnwrap(disk.saved), id = try XCTUnwrap(store.activeWorkspaceId)
        let data = try JSONEncoder().encode(PersistedWindow(id: store.windowID, state: state))
        let cases: [(Any?, Set<UUID>)] = [(nil, []), (false, []), ("bad", []),
                                        ([id.uuidString, "not-a-uuid", id.uuidString], [id])]
        for (value, expected) in cases {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var fields = try XCTUnwrap(json["state"] as? [String: Any])
            fields["leftNavigation"] = ["railVisible": false, "panelVisible": false,
                                        "collapsedWorkspaceIDs": value ?? NSNull()]
            json["state"] = fields
            let decoded = try JSONDecoder().decode(PersistedWindow.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.state.workspaces, state.workspaces)
            XCTAssertEqual(decoded.state.leftNavigation?.collapsedWorkspaceIDs, expected)
            XCTAssertEqual(decoded.state.leftNavigation?.railVisible, false)
        }
        let legacy = try JSONDecoder().decode(LeftNavigationPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.collapsedWorkspaceIDs.isEmpty)
    }

    func testCollapseKeepsStrongestMarkAndNeverRecapturesAttentionOrWritesDuringReadout() async throws {
        let scope = TeamServiceTestScope(); defer { scope.close() }
        let disk = InMemoryPersistence(), store = makeTestStore(persistence: disk), ledger = AttentionLedger()
        defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active), input = try XCTUnwrap(workspace.activeSession)
        let failed = store.addTab(in: workspace)
        failed.activityState = .idle; failed.lastCommandExit = 1
        for (tab, kind) in [(input, AttentionKind.input), (failed, .failure)] {
            ledger.upsert(.init(source: "terminal", object: tab.id.uuidString, episode: tab.attentionEpisode,
                                kind: kind, destination: .terminal(tab.id)))
        }
        var captures = 0
        let attention = AttentionSidebarModel(ledger: ledger, storesProvider: { captures += 1; return [store] })
        let original = attention.projection, builds = attention.projectionBuildCount, reads = captures
        let owner = AttentionWorkspaceID(window: store.windowID, workspace: workspace.id)
        XCTAssertEqual(attention.workspaceIndicators[owner]?.kind, .needsInput)
        XCTAssertEqual(attention.workspaceIndicators[owner]?.reasonIDs.count, 2)
        let entries = store.workspaceRailEntries(attention: attention)
        for _ in 0..<10 {
            store.toggleWorkspaceTabs(workspace.id)
            await Task.yield()
            let saves = disk.saveCount
            for query in ["", input.title] {
                _ = WorkspaceRailSearch.matches(entries, query: query,
                    collapsedWorkspaceIDs: store.leftNavigation.collapsedWorkspaceIDs)
                _ = attention.workspaceIndicators[owner]
            }
            XCTAssertEqual(disk.saveCount, saves)
        }
        XCTAssertEqual(captures, reads)
        XCTAssertEqual(attention.projectionBuildCount, builds)
        XCTAssertEqual(attention.projection, original)
    }
}
