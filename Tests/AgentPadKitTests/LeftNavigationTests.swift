import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class LeftNavigationTests: XCTestCase {
    func testFourCombinationsAreIndependentAndPersistPerWindow() throws {
        let aDisk = InMemoryPersistence(), bDisk = InMemoryPersistence()
        let a = makeTestStore(persistence: aDisk), b = makeTestStore(persistence: bDisk)
        defer { a.terminate(); b.terminate() }
        a.chatNavigation.query = "keep the filter"
        a.attentionExpanded = true
        let ids = a.allSessions.map(\.id)
        for rail in [false, true] {
            for panel in [false, true] {
                a.leftNavigation = .init(railVisible: rail, panelVisible: panel, panelContent: .files)
                a.toggleWorkspaceRail()
                XCTAssertEqual(a.leftNavigation, .init(railVisible: !rail, panelVisible: panel, panelContent: .files))
                a.toggleNavigationPanel()
                XCTAssertEqual(a.leftNavigation, .init(railVisible: !rail, panelVisible: !panel, panelContent: .files))
                XCTAssertEqual(b.leftNavigation, .init())
                a.flushPersistence(); b.flushPersistence()
                let restored = makeTestStore(persistence: InMemoryPersistence(initial: aDisk.saved))
                XCTAssertEqual(restored.leftNavigation, a.leftNavigation)
                XCTAssertEqual(restored.allSessions.map(\.id), ids)
                XCTAssertEqual(restored.navigationPresentation, .init())
                restored.terminate()
            }
        }
        XCTAssertEqual(a.chatNavigation.query, "keep the filter")
        XCTAssertTrue(a.attentionExpanded)
    }

    func testEveryLegacyModeAndContentMigratesOnceWithoutChangingTabsOrSections() throws {
        let seed = InMemoryPersistence(), original = makeTestStore(persistence: seed)
        original.flushPersistence(); original.terminate()
        for mode in [SidebarMode.full, .compact, .hidden] {
            for content in [SidebarContent.workspaces, .files, .team, .chat] {
                var old = try XCTUnwrap(seed.saved)
                old.leftNavigation = nil; old.sidebarMode = mode
                old.sidebarSelectedContent = content.rawValue
                old.sidebarWidth = 310
                old.chatSidebarPreferences = ChatSidebarPreferences(attentionCollapsed: true, width: 299)
                let disk = InMemoryPersistence(initial: old), store = makeTestStore(persistence: disk)
                XCTAssertEqual(store.leftNavigation.railVisible, mode != .hidden)
                XCTAssertEqual(store.leftNavigation.panelVisible, mode == .full)
                XCTAssertEqual(store.leftNavigation.panelContent.rawValue, content == .workspaces ? "chat" : content.rawValue)
                XCTAssertEqual(store.sidebarWidth, 310)
                XCTAssertEqual(store.chatSidebarPreferences.attentionCollapsed, true)
                XCTAssertEqual(store.chatSidebarPreferences.width, 299)
                store.flushPersistence(); store.terminate()
                var saved = try XCTUnwrap(disk.saved)
                XCTAssertEqual(saved.workspaces, old.workspaces)
                let preference = saved.leftNavigation
                saved.sidebarMode = .full; saved.sidebarSelectedContent = "files"
                let again = makeTestStore(persistence: InMemoryPersistence(initial: saved))
                XCTAssertEqual(again.leftNavigation, preference)
                again.terminate()
            }
        }
    }

    func testDamagedNewLayoutDoesNotRecoverTheWindowAndFalseIsNotMissing() throws {
        let seed = InMemoryPersistence(), store = makeTestStore(persistence: seed)
        store.flushPersistence(); store.terminate()
        let state = try XCTUnwrap(seed.saved)
        let data = try JSONEncoder().encode(PersistedWindow(id: UUID(), state: state))
        let payloads: [Any] = ["bad", 17, ["railVisible": false, "panelVisible": false, "panelContent": "future"],
                              ["railVisible": "false", "panelVisible": 0], [:]]
        for payload in payloads {
            var window = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var fields = try XCTUnwrap(window["state"] as? [String: Any])
            fields["leftNavigation"] = payload; window["state"] = fields
            let restored = try JSONDecoder().decode(PersistedWindow.self, from: JSONSerialization.data(withJSONObject: window))
            XCTAssertEqual(restored.state.workspaces, state.workspaces)
            XCTAssertNotNil(restored.state.leftNavigation)
            XCTAssertEqual(restored.state.leftNavigation?.panelContent, .chat)
        }
        let falseValues = try JSONDecoder().decode(LeftNavigationPreferences.self,
            from: Data(#"{"railVisible":false,"panelVisible":false}"#.utf8))
        XCTAssertEqual(falseValues, .init(railVisible: false, panelVisible: false))
    }

    func testLegacyProjectionAndWidthClamps() throws {
        let disk = InMemoryPersistence(), store = makeTestStore(persistence: disk)
        defer { store.terminate() }
        for rail in [false, true] {
            for panel in [false, true] {
                store.leftNavigation = .init(railVisible: rail, panelVisible: panel, panelContent: .team)
                store.flushPersistence()
                XCTAssertEqual(disk.saved?.sidebarMode, panel ? .full : rail ? .compact : .hidden)
                XCTAssertEqual(disk.saved?.sidebarSelectedContent, panel ? "team" : "workspaces")
                XCTAssertEqual(disk.saved?.sidebarContent, .workspaces)
            }
        }
        XCTAssertEqual(ChatSidebarPreferences.clampWidth(.infinity), 268)
        XCTAssertEqual(ChatSidebarPreferences.clampWidth(800), 320)
        XCTAssertEqual(SidebarView.clampWidth(.nan), 268)
        XCTAssertEqual(SidebarView.clampWidth(800), 480)
    }

    func testWidthsThresholdAndSplitMinimumUseOverlaysWithoutDoubleSeparators() {
        let preferences = LeftNavigationPreferences()
        var state = LeftNavigationPresentation()
        func layout(_ width: CGFloat, tree: CGFloat = 200) -> LeftNavigationLayout {
            .init(preferences: preferences, presentation: state, availableWidth: width, panelWidth: 268, minimumTreeWidth: tree)
        }
        XCTAssertEqual(layout(900).leadingWidth, 326)
        XCTAssertEqual(layout(899).leadingWidth, 58)
        state.list = .expanded
        XCTAssertEqual(layout(1100).railWidth, 252)
        XCTAssertEqual(layout(1100).leadingWidth, 520)
        XCTAssertEqual(layout(400).railWidth, 58)
        XCTAssertEqual(layout(400).listOverlayWidth, 252)
        XCTAssertTrue(layout(950, tree: 650).narrow)
        state.list = .peek
        XCTAssertEqual(layout(1000).listOverlayWidth, 268)
        XCTAssertEqual(layout(220).listOverlayWidth, 204)
    }

    func testNarrowPanelRetainsPreferenceAndTransientSurfacesAreExclusive() {
        let store = makeTestStore(); defer { store.terminate() }
        let preference = store.leftNavigation
        func resize(_ width: CGFloat) {
            store.updateNavigationGeometry(.init(preferences: store.leftNavigation,
                presentation: store.navigationPresentation, availableWidth: width, panelWidth: 300))
        }
        resize(800)
        XCTAssertFalse(store.panelIsPresented)
        store.toggleNavigationPanel()
        XCTAssertTrue(store.navigationPresentation.narrowPanelOpen)
        XCTAssertEqual(store.leftNavigation, preference)
        store.openWorkspaceList()
        XCTAssertFalse(store.navigationPresentation.narrowPanelOpen)
        store.toggleNavigationPanel()
        XCTAssertEqual(store.navigationPresentation.list, .closed)
        XCTAssertTrue(store.handleNavigationEscape())
        XCTAssertFalse(store.handleNavigationEscape())
        store.toggleNavigationPanel(); resize(1100)
        XCTAssertFalse(store.navigationPresentation.narrowPanelOpen)
        XCTAssertTrue(store.panelIsPresented)
        XCTAssertEqual(store.leftNavigation, preference)
    }

    func testSectionChoiceAndWorkspaceSwitchKeepRailPreference() throws {
        let store = makeTestStore(); defer { store.terminate() }
        store.toggleWorkspaceRail()
        store.selectNavigationPanel(.files)
        XCTAssertFalse(store.leftNavigation.railVisible)
        XCTAssertTrue(store.leftNavigation.panelVisible)
        store.selectNavigationPanel(.files)
        XCTAssertFalse(store.leftNavigation.panelVisible)
        store.selectNavigationPanel(.team)
        let state = store.leftNavigation
        let first = try XCTUnwrap(store.active)
        store.addWorkspace(); store.activateWorkspace(first)
        XCTAssertEqual(store.leftNavigation, state)
        store.requestRenameActiveWorkspace()
        XCTAssertEqual(store.navigationPresentation.list, .peek)
        first.nameEdit.text = "Changed"
        XCTAssertTrue(store.handleNavigationEscape())
        XCTAssertNil(first.customTitle)
        XCTAssertEqual(store.navigationPresentation.list, .peek)
    }
}
