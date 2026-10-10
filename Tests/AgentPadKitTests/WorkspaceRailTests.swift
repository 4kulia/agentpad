import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class WorkspaceRailTests: XCTestCase {
    func testTabOnlyMatchKeepsWorkspaceAndReturnTargetsExactTab() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let workspace = try XCTUnwrap(store.active), original = try XCTUnwrap(workspace.activeSession)
        store.renameWorkspace(workspace, to: "Cedar")
        original.customTitle = "Deploy production"
        let other = store.addTab(in: workspace); other.customTitle = "Logs"
        let second = store.addWorkspace(); store.renameWorkspace(second, to: "Other")
        let matches = WorkspaceRailSearch.matches(store.workspaceRailEntries(), query: "  PRODUCTION  ")
        XCTAssertEqual(matches.map(\.id), [workspace.id])
        XCTAssertFalse(try XCTUnwrap(matches.first).workspaceMatches)
        let destinations = WorkspaceRailSearch.destinations(matches)
        XCTAssertEqual(destinations, [.init(workspaceID: workspace.id, sessionID: original.id)])
        store.openWorkspaceList()
        XCTAssertTrue(store.activateRailDestination(try XCTUnwrap(destinations.first)))
        XCTAssertEqual(store.activeWorkspaceId, workspace.id)
        XCTAssertTrue(workspace.activeSession === original)
        XCTAssertEqual(store.navigationPresentation.list, .closed)
    }

    func testWorkspaceNameMatchesAllTabsAndArrowsDoNotActivate() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let original = try XCTUnwrap(store.active)
        let target = store.addWorkspace(); store.renameWorkspace(target, to: "Birch")
        store.activateWorkspace(original)
        let rows = WorkspaceRailSearch.destinations(WorkspaceRailSearch.matches(store.workspaceRailEntries(), query: "birch"))
        XCTAssertEqual(rows.first, .init(workspaceID: target.id))
        XCTAssertEqual(rows.count, target.root.allPanes.flatMap(\.tabs).count + 1)
        XCTAssertEqual(WorkspaceRailSearch.moved(nil, by: 1, in: rows), rows.first)
        XCTAssertEqual(WorkspaceRailSearch.moved(rows.last, by: 1, in: rows), rows.last)
        XCTAssertEqual(store.activeWorkspaceId, original.id)
        XCTAssertFalse(store.activateRailDestination(.init(workspaceID: target.id, sessionID: UUID())))
        XCTAssertEqual(store.activeWorkspaceId, original.id)
    }

    func testReorderSearchAndWorkspaceShortcutsShareFlatOrder() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let parent = try XCTUnwrap(store.active)
        let child = store.addWorkspace(); child.worktreeParentId = parent.id
        let other = store.addWorkspace()
        store.moveWorkspace(from: 0, to: 2)
        XCTAssertEqual(store.workspaces.map(\.id), [other.id, parent.id, child.id])
        XCTAssertEqual(store.workspaceRailEntries().map(\.id), store.workspaces.map(\.id))
        store.activateWorkspace(other)
        store.performNavigationCommand(.nextWorkspace)
        XCTAssertEqual(store.activeWorkspaceId, parent.id)
        store.performNavigationCommand(.nextWorkspace)
        XCTAssertEqual(store.activeWorkspaceId, child.id)
    }

    func testInternalFileMarkerRetainsURLAndClearsAfterCancelledDrag() throws {
        let token = UUID(), board = NSPasteboard.withUniqueName()
        defer { InternalFileDrag.end(token); board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp")
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(token.uuidString, forType: InternalFileDrag.type)
        board.writeObjects([item]); InternalFileDrag.begin(token)
        XCTAssertEqual(board.string(forType: .fileURL), url.absoluteString)
        XCTAssertTrue(InternalFileDrag.rejectsFolderDrop(hasMarker: board.types?.contains(InternalFileDrag.type) == true))
        XCTAssertTrue(InternalFileDrag.rejectsFolderDrop(hasMarker: false), "Live session covers conversions which strip custom types")
        InternalFileDrag.end(token)
        XCTAssertFalse(InternalFileDrag.rejectsFolderDrop(hasMarker: false), "External Finder folders remain accepted")
        XCTAssertTrue(InternalFileDrag.rejectsFolderDrop(hasMarker: true), "Stale marked data is still internal")
    }

    func testReorderNeverSplitsDestinationWorktreeFamily() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let moving = try XCTUnwrap(store.active)
        let parent = store.addWorkspace()
        let child = store.addWorkspace(); child.worktreeParentId = parent.id
        store.moveWorkspace(from: 0, to: 1)
        XCTAssertEqual(store.workspaces.map(\.id), [parent.id, child.id, moving.id])
        store.moveWorkspace(from: 2, to: 1)
        XCTAssertEqual(store.workspaces.map(\.id), [moving.id, parent.id, child.id])
    }

    func testSearchRevealsCollapsedWorktreesWithoutChangingFlatOrder() throws {
        let store = makeTestStore(); defer { store.terminate() }
        let parent = try XCTUnwrap(store.active)
        let child = store.addWorkspace(); child.worktreeParentId = parent.id
        child.activeSession?.customTitle = "Subtask result"
        let other = store.addWorkspace()
        let entries = store.workspaceRailEntries()
        XCTAssertEqual(WorkspaceRailSearch.matches(entries, query: "", collapsedParents: [parent.id]).map(\.id), [parent.id, other.id])
        let matches = WorkspaceRailSearch.matches(entries, query: "Subtask", collapsedParents: [parent.id])
        XCTAssertEqual(matches.map(\.id), [child.id])
        XCTAssertEqual(WorkspaceRailSearch.destinations(matches).first?.sessionID, child.activeSession?.id)
        XCTAssertEqual(store.workspaces.map(\.id), [parent.id, child.id, other.id])
    }

    func testHiddenDragPeekAndCancellationDoNotPersistRailVisibility() async throws {
        let disk = InMemoryPersistence(), store = makeTestStore(persistence: disk)
        defer { store.terminate() }
        store.leftNavigation.railVisible = false
        store.setRailDragTarget("header", entered: true)
        store.openWorkspaceList(forDrag: true)
        XCTAssertEqual(store.navigationPresentation.list, .peek)
        store.setRailDragTarget("header", entered: false)
        store.setRailDragTarget("row", entered: true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(store.navigationPresentation.list, .peek)
        store.setRailDragTarget("row", entered: false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(store.navigationPresentation.list, .closed)
        store.openWorkspaceList(forDrag: true); store.finishNavigationDrag()
        XCTAssertEqual(store.navigationPresentation.list, .closed)
        XCTAssertFalse(store.leftNavigation.railVisible)
        store.flushPersistence()
        XCTAssertEqual(disk.saved?.leftNavigation?.railVisible, false)
    }
}
