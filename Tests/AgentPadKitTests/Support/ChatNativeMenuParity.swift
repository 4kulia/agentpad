import AppKit
import AgentPadQuietTestSupport
import XCTest
@testable import AgentPadKit

/// Compare the menus AppKit actually receives, including empty submenus and
/// separators. Array equality preserves order at every depth.
@MainActor enum ChatNativeMenuParity {
    struct Item: Codable, Equatable {
        var title: String
        var enabled: Bool
        var state: Int
        var separator: Bool
        var submenu: [Item]?
    }

    static func items(_ menu: NSMenu) -> [Item] {
        menu.items.map {
            Item(title: $0.title, enabled: $0.isEnabled, state: $0.state.rawValue,
                 separator: $0.isSeparatorItem, submenu: $0.submenu.map(items))
        }
    }

    static func legacy(in host: ChatQuietHost) throws -> NSMenu? {
        APQuietSelectWindow(host.window)
        let row = try XCTUnwrap(ChatTimelineReferenceCapture.descendants(host.view, ChatTimelineParityProbeView.self)
            .first { $0.role == "row" && !$0.isHiddenOrHasHiddenAncestor })
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: row.convert(CGPoint(x: 10, y: 4), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        return host.view.menu(for: event)
    }

    static func dispatch(_ title: String, in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) throws {
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title }, file: file, line: line)
        XCTAssertTrue(menu.items[index].isEnabled, title, file: file, line: line)
        XCTAssertNotNil(menu.items[index].action, title, file: file, line: line)
        menu.performActionForItem(at: index)
    }

    /// Drive the same configure/unbind path as NSTableView reuse on one attached
    /// cell. Retain the old NSMenu so stale callbacks are exercised as well.
    static func reusedMenu(_ f: ChatNativeActionFixture, from sourceID: String, to targetID: String) throws -> (ChatNativeShellCell, NSMenu, NSMenu) {
        let cell = try f.row(sourceID)
        let snapshot = try XCTUnwrap(f.coordinator.snapshot)
        let layout = ChatTimelineLayout()
        let sourceIndex = try XCTUnwrap(f.coordinator.messageIndex(sourceID))
        let source = snapshot.rows[sourceIndex], sourcePlan = try XCTUnwrap(f.coordinator.layoutPlan(at: sourceIndex))
        cell.configure(row: source, epoch: snapshot.presentationEpoch, plan: sourcePlan,
            content: layout.content(source, snapshot: snapshot, width: sourcePlan.width), actions: f.adapter.actions)
        cell.configureActions(row: source, snapshot: snapshot, actions: f.adapter.actions, layer: f.coordinator.editorLayer)
        XCTAssertEqual(cell.binding?.id, source.id)
        let old = try XCTUnwrap(cell.rowActions.makeMenu())
        let index = try XCTUnwrap(f.coordinator.messageIndex(targetID))
        let row = snapshot.rows[index], plan = try XCTUnwrap(f.coordinator.layoutPlan(at: index))
        let before = try XCTUnwrap(cell.binding)
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
            content: layout.content(row, snapshot: snapshot, width: plan.width), actions: f.adapter.actions)
        cell.configureActions(row: row, snapshot: snapshot, actions: f.adapter.actions, layer: f.coordinator.editorLayer)
        XCTAssertNotEqual(cell.binding?.id, before.id)
        XCTAssertEqual(cell.binding?.id, row.id)
        XCTAssertTrue(cell.window === f.host.window)
        return (cell, old, try XCTUnwrap(cell.rowActions.makeMenu()))
    }
}
