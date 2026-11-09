import AppKit
import AgentPadQuietTestSupport
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeTimelineInfrastructureTests: XCTestCase {
    private typealias F = ChatTimelineW01
    private typealias S = NativeTimelineSnapshot

    override func setUp() async throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Run through scripts/test-quiet.py", code: 1) }
        _ = NSApplication.shared
        AgentPadFonts.registerOnce()
    }

    func testStableDifferenceUsesSequentialIndexesAndRejectsDuplicateIDs() throws {
        func ids(_ names: [String]) -> [S.RowID] { names.map { .init(conversation: F.conversation(), kind: .message($0)) } }
        let old = ids(["a", "b", "c", "d"]), new = ids(["d", "b", "e", "a"])
        let difference = try XCTUnwrap(ChatTimelineDifference(from: old, to: new))
        XCTAssertEqual(difference.operations, [.remove(2), .move(from: 2, to: 0), .move(from: 2, to: 1), .insert(2, new[2])])
        let variants = [[], ["a"], ["b", "a"], ["a", "b", "c", "d"], ["d", "c", "b", "a"],
                        ["b", "d", "a", "c"], ["e", "b", "a"], ["d", "b", "e", "a"]]
        for source in variants {
            for target in variants {
                var actual = ids(source)
                let delta = try XCTUnwrap(ChatTimelineDifference(from: actual, to: ids(target)))
                for operation in delta.operations {
                    switch operation {
                    case .remove(let index): actual.remove(at: index)
                    case .insert(let index, let id): actual.insert(id, at: index)
                    case .move(let from, let to): actual.insert(actual.remove(at: from), at: to)
                    }
                }
                XCTAssertEqual(actual, ids(target), "\(source) → \(target)")
            }
        }
        XCTAssertNil(ChatTimelineDifference(from: old, to: [old[0], old[0]]))
        XCTAssertNil(ChatTimelineDifference(from: [old[0], old[0]], to: new))
    }

    func testNativeFixtureMountsAllFourPanesThroughTheSingleSeam() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w02-seam-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for dm in [false, true] {
            for root in [nil, "a"] as [String?] {
                let model = ChatTimelineW01Model(directory: directory.appendingPathComponent(UUID().uuidString))
                model.isDM = dm; model.threadRoot = root
                model.feed.messages = [F.message("a", dm: dm), F.message("b", seq: 2, root: root, dm: dm)]
                let timeline = ChatTimelineView(model: model, root: root, members: F.members, mentionable: [],
                    me: "w01-me", archived: false, ownerModel: nil)
                let hosting = NSHostingView(rootView: AnyView(timeline))
                let host = ChatQuietHost(view: hosting, dark: false, width: root == nil ? 760 : 420)
                try await host.settle()
                let tables = descendants(host.view, NSTableView.self)
                XCTAssertEqual(tables.count, 1)
                let table = try XCTUnwrap(tables.first)
                XCTAssertEqual(table.tableColumns.count, 1)
                XCTAssertNil(table.headerView)
                XCTAssertEqual(table.intercellSpacing, .zero)
                XCTAssertFalse(table.usesAutomaticRowHeights)
                XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
                XCTAssertEqual(table.gridStyleMask, [])
                XCTAssertEqual(table.selectionHighlightStyle, .none)
                XCTAssertFalse(table.allowsMultipleSelection)
                XCTAssertFalse(descendants(table, NSView.self).contains { String(reflecting: type(of: $0)).contains("NSHosting") })
                let coordinator = try XCTUnwrap(table.dataSource as? NativeChatTimelineCoordinator)
                XCTAssertEqual(coordinator.snapshot?.messageIDs, ["a", "b"])
                XCTAssertEqual(coordinator.snapshot?.state.accessibilityLabel, root == nil ? (dm ? "Direct messages" : "Channel messages") : "Thread messages")
                XCTAssertTrue(model.readingCalls.contains("begin:\(root ?? "feed")"),
                    "The default product mount starts the owning pane's reading visit")
                hosting.rootView = AnyView(EmptyView())
                try await host.settle()
                host.close()
                XCTAssertEqual(model.readingCalls.filter { $0 == "end:\(root ?? "feed")" }.count, 1)
                XCTAssertTrue(coordinator.rows.isEmpty)
                XCTAssertEqual(coordinator.layoutEngine.heights.count, 0)
                XCTAssertEqual(coordinator.layoutEngine.contents.count, 0)
                await model.service.disconnect()
            }
        }
    }

    func testNativeInsertDeleteMoveAndReconfigureKeepCellIdentity() async throws {
        for dark in [false, true] {
            for root in [nil, "root"] as [String?] {
                let builder = ChatTimelineSnapshotBuilder()
                let width: CGFloat = root == nil ? 760 : 420
                let base = F.style(appearance: dark ? "DarkAqua" : "Aqua")
                let style = S.Style(metrics: base.metrics, colors: [
                    "foreground": dark ? .init(red: 239/255, green: 239/255, blue: 241/255, alpha: 1) : .init(red: 56/255, green: 58/255, blue: 66/255, alpha: 1),
                    "surface": dark ? .init(red: 40/255, green: 44/255, blue: 52/255, alpha: 1) : .init(red: 250/255, green: 250/255, blue: 250/255, alpha: 1)
                ], appearance: base.appearance, increasedContrast: false, alwaysShowTime: false)
                func snapshot(_ names: [String], selected: String? = nil, long: String? = nil) -> S {
                    let messages = names.enumerated().map { index, name in
                        var message = F.message(name, seq: index + 1, root: root)
                        if name == long { message.text = String(repeating: "A wrapped native shell body. ", count: 20) }
                        return F.content(message)
                    }
                    return builder.build(F.input(messages: messages, visuals: names.map { F.visual(selected: $0 == selected) }, root: root, style: style))
                }
                let coordinator = NativeChatTimelineCoordinator()
                let container = NativeChatTimelineContainer(coordinator: coordinator)
                let host = ChatQuietHost(view: container, dark: dark, width: width, height: 600)
                defer { coordinator.dispose(); host.close() }
                let initial = snapshot(["a", "b", "c", "d"])
                container.update(initial)
                try await host.settle()
                try assertTable(coordinator, snapshot: initial)
                let b = try cell("b", in: coordinator)
                let d = try cell("d", in: coordinator)
                XCTAssertTrue(b.body.isSelectable)
                XCTAssertFalse(b.body.isEditable)
                XCTAssertFalse(b.body.canBecomeKeyView)
                b.body.setSelectedRange(NSRange(location: 1, length: 3))
                let initialBinding = try XCTUnwrap(b.binding)
                let storage = b.body.textStorage
                try capture(host, name: "initial-\(Int(width))-\(dark)")

                let selected = snapshot(["a", "b", "c", "d"], selected: "b")
                container.update(selected); try await host.settle()
                XCTAssertTrue(try cell("b", in: coordinator) === b)
                XCTAssertTrue(b.body.textStorage === storage)
                XCTAssertEqual(b.body.selectedRange(), NSRange(location: 1, length: 3))
                XCTAssertFalse(b.apply(ifCurrent: initialBinding) { _ in XCTFail("Old revision painted") })
                XCTAssertEqual(coordinator.lastDifference?.operations, [])
                XCTAssertEqual(coordinator.fullReloads, 1)

                let updated = snapshot(["d", "b", "e", "a"], selected: "b", long: "a")
                container.update(updated); try await host.settle()
                try assertTable(coordinator, snapshot: updated)
                XCTAssertTrue(try cell("b", in: coordinator) === b, "A retained moved view must stay bound to b")
                XCTAssertTrue(try cell("d", in: coordinator) === d, "Moving d to the first message retains its native cell")
                XCTAssertEqual(b.body.selectedRange(), NSRange(location: 1, length: 3))
                XCTAssertEqual(coordinator.fullReloads, 1, "A structural transaction must not reload the table")
                XCTAssertTrue(try XCTUnwrap(coordinator.lastDifference).operations.contains { if case .move = $0 { true } else { false } })
                XCTAssertGreaterThan(try XCTUnwrap(coordinator.plans[updated.rows.first { $0.messageID == "a" }!.id]).height,
                                     try XCTUnwrap(coordinator.plans[updated.rows.first { $0.messageID == "b" }!.id]).height)
                try capture(host, name: "updated-\(Int(width))-\(dark)")
                let empty = snapshot([])
                container.update(empty); try await host.settle()
                try assertTable(coordinator, snapshot: empty)
                XCTAssertEqual(coordinator.fullReloads, 1)
                XCTAssertEqual(coordinator.layoutEngine.heights.count, empty.rows.count)
            }
        }
    }

    func testPreparedGenerationsRejectSupersededWidthAppearancePaneAndDisposal() throws {
        let builder = ChatTimelineSnapshotBuilder(), coordinator = NativeChatTimelineCoordinator()
        let first = builder.build(F.input(messages: [F.content(F.message("a"))]))
        let request = try XCTUnwrap(coordinator.begin(first, width: 760))
        let prepared = try XCTUnwrap(coordinator.prepare(request))
        let resized = try XCTUnwrap(coordinator.begin(first, width: 420))
        XCTAssertNil(coordinator.prepare(request))
        XCTAssertFalse(coordinator.commit(prepared))
        XCTAssertTrue(coordinator.commit(try XCTUnwrap(coordinator.prepare(resized))))
        XCTAssertFalse(coordinator.commit(try XCTUnwrap(coordinator.prepare(resized))), "Consume a generation once")
        let dark = builder.build(F.input(messages: [F.content(F.message("a"))], style: F.style(appearance: "DarkAqua")))
        XCTAssertTrue(coordinator.update(dark, width: 420))
        XCTAssertNil(coordinator.begin(first, width: 760), "Older snapshot cannot start new work")
        XCTAssertFalse(coordinator.commit(prepared))
        let obsolete = try XCTUnwrap(coordinator.prepare(try XCTUnwrap(coordinator.begin(dark, width: 420))))
        let replaced = builder.build(F.input(messages: [F.content(F.message("a", dm: true))], dm: true, epoch: F.otherEpoch))
        XCTAssertTrue(coordinator.update(replaced, width: 420))
        XCTAssertFalse(coordinator.commit(obsolete))
        XCTAssertEqual(coordinator.snapshot, replaced)
        XCTAssertEqual(coordinator.fullReloads, 2)
        let pending = try XCTUnwrap(coordinator.prepare(try XCTUnwrap(coordinator.begin(replaced, width: 421))))
        coordinator.dispose()
        XCTAssertFalse(coordinator.commit(pending))
        XCTAssertNil(coordinator.begin(first, width: 760))
        XCTAssertEqual(coordinator.layoutEngine.heights.count, 0)
        XCTAssertEqual(coordinator.layoutEngine.contents.count, 0)
        XCTAssertNil(coordinator.tableView.dataSource)
        XCTAssertNil(coordinator.tableView.delegate)
    }

    func testReusableShellCancelsOwnedWorkAndClearsPreviousPresentation() throws {
        let builder = ChatTimelineSnapshotBuilder(), engine = ChatTimelineLayout()
        let first = builder.build(F.input(messages: [F.content(F.message("a"))]))
        let row = try XCTUnwrap(first.rows.first { $0.messageID == "a" })
        let width = ChatTimelineWidth(760, scale: 2)
        let shell = ChatNativeShellCell(kind: .message)
        shell.configure(row: row, epoch: first.presentationEpoch, plan: engine.plan(row, snapshot: first, width: width),
                        content: engine.content(row, snapshot: first, width: width))
        let token = try XCTUnwrap(shell.binding)
        var cancellations = 0
        shell.cancelOnUnbind { cancellations += 1 }
        shell.body.setSelectedRange(NSRange(location: 1, length: 3))
        shell.toolTip = "Previous message"; shell.menu = NSMenu(title: "Previous actions")
        shell.setAccessibilityHelp("Previous help")
        shell.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways], owner: shell))
        let second = builder.build(F.input(messages: [F.content(F.message("b"))]))
        let other = try XCTUnwrap(second.rows.first { $0.messageID == "b" })
        shell.configure(row: other, epoch: second.presentationEpoch, plan: engine.plan(other, snapshot: second, width: width),
                        content: engine.content(other, snapshot: second, width: width))
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(shell.apply(ifCurrent: token) { $0.body.string = "Stale async bytes" })
        XCTAssertEqual(shell.body.string, "Text b")
        XCTAssertEqual(shell.body.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(shell.menu); XCTAssertNil(shell.toolTip); XCTAssertNil(shell.accessibilityHelp())
        XCTAssertTrue(shell.trackingAreas.isEmpty)
        let fullTime = try XCTUnwrap(ChatFeedLayout.date("2026-10-06T12:00:00Z"))
            .formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
        XCTAssertEqual(shell.accessibilityLabel(), "Anna, \(fullTime)")
        XCTAssertTrue(shell.apply(ifCurrent: try XCTUnwrap(shell.binding)) { $0.toolTip = "Current" })
        shell.unbind()
        XCTAssertNil(shell.binding); XCTAssertNil(shell.plan); XCTAssertEqual(shell.body.string, "")
        XCTAssertNil(shell.accessibilityLabel()); XCTAssertNil(shell.toolTip)
    }

    func testRealTableReusesCellsWhileScrollingExtendedHistory() async throws {
        let builder = ChatTimelineSnapshotBuilder(), coordinator = NativeChatTimelineCoordinator()
        let snapshot = builder.build(F.input(messages: (0..<120).map { (index: Int) in F.content(F.message("m-\(index)", seq: index)) }))
        XCTAssertEqual(snapshot.messageIDs, (0..<120).map { "m-\($0)" })
        let host = ChatQuietHost(view: NativeChatTimelineContainer(coordinator: coordinator), dark: false, height: 260)
        defer { coordinator.dispose(); host.close() }
        (host.view as! NativeChatTimelineContainer).update(snapshot)
        try await host.settle()
        for target: Int in [90, 1, 110, 10] {
            let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == "m-\(target)" }, "Missing target \(target); IDs: \(snapshot.messageIDs)")
            let index = try XCTUnwrap(coordinator.indexes[row.id])
            coordinator.tableView.scrollRowToVisible(index)
            try await host.settle()
            try assertTable(coordinator, snapshot: snapshot, visibleOnly: true)
        }
        XCTAssertGreaterThan(coordinator.cellsReused, 0)
        XCTAssertLessThan(coordinator.cellsCreated, 70, "The extended fixture must exercise virtualization")
        XCTAssertEqual(coordinator.fullReloads, 1)
    }

    private func cell(_ id: String, in coordinator: NativeChatTimelineCoordinator) throws -> ChatNativeShellCell {
        let row = try XCTUnwrap(coordinator.rows.firstIndex { $0.messageID == id })
        return try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ChatNativeShellCell)
    }
    private func assertTable(_ coordinator: NativeChatTimelineCoordinator, snapshot: S, visibleOnly: Bool = false) throws {
        XCTAssertEqual(coordinator.rows, snapshot.rows)
        XCTAssertEqual(coordinator.tableView.numberOfRows, snapshot.rows.count)
        XCTAssertEqual(coordinator.indexes, Dictionary(uniqueKeysWithValues: snapshot.rows.enumerated().map { ($0.element.id, $0.offset) }))
        for (index, row) in snapshot.rows.enumerated() {
            let plan = try XCTUnwrap(coordinator.plans[row.id])
            XCTAssertEqual(coordinator.tableView.rect(ofRow: index).height, plan.height, accuracy: 0.01)
            guard let cell = coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: !visibleOnly) as? ChatNativeShellCell else { continue }
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.binding?.id, row.id)
            XCTAssertEqual(cell.identifier, ChatNativeShellKind(row.payload).identifier)
            XCTAssertEqual(cell.plan, plan)
            XCTAssertEqual(cell.body.isHidden ? cell.placeholder.frame : cell.body.frame, plan.body)
        }
    }
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }
    private func capture(_ host: ChatQuietHost, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_NATIVE_W02_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        XCTAssertGreaterThan(Set(Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)).count, 8,
                             "A shell capture must include rendered text, not just a blank surface")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        XCTAssertNil(APQuietFailure())
    }
}
