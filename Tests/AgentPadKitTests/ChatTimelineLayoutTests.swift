import AppKit
import AgentPadQuietTestSupport
import XCTest
@testable import AgentPadKit

@MainActor final class ChatTimelineLayoutTests: XCTestCase {
    private typealias F = ChatTimelineW01

    func testArchivedOversizedDraftFooterReflowsInsideTheSharedRowReservation() async throws {
        let f = try await ChatNativeActionFixture(count: 2, width: 420)
        defer { f.dispose() }
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        session.editor.selectAll(nil)
        session.editor.insertText(String(repeating: "An oversized draft. ", count: 900), replacementRange: session.editor.selectedRange())
        session.host.save.performClick(nil)
        try await f.settle()
        XCTAssertEqual(f.model.editing?.problem, "The message is too long: at most 16 KiB.")
        try f.base.write("UPDATE channels SET archived = 1")
        try await f.settle()
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertFalse(session.host.save.isEnabled)
        var heights: [CGFloat] = []
        for width: CGFloat in [420, 760, 420] {
            f.view.setFrameSize(NSSize(width: width, height: 400))
            f.view.layoutSubtreeIfNeeded()
            try await f.settle()
            let index = try XCTUnwrap(f.coordinator.messageIndex(f.messages[0].id))
            let plan = try XCTUnwrap(f.coordinator.layoutPlan(at: index))
            let host = session.host
            let footerHeight = max(24, host.loading.frame.height, host.problem.frame.height, host.readOnly.frame.height)
            XCTAssertEqual(host.footerFrame.height, footerHeight)
            XCTAssertEqual(plan.editor.height, 204 + footerHeight)
            XCTAssertEqual(host.frame.height, plan.editor.height)
            for control in [host.save, host.cancel, host.loading, host.problem, host.readOnly] where !control.isHidden {
                XCTAssertTrue(host.footerFrame.contains(control.frame), "Footer must contain \(control.accessibilityLabel() ?? "control")")
            }
            XCTAssertGreaterThanOrEqual(f.coordinator.tableView.rect(ofRow: index + 1).minY, host.frame.maxY)
            heights.append(plan.editor.height)
        }
        XCTAssertGreaterThan(heights[0], heights[1], "Narrow error wrapping must expand the row")
        XCTAssertEqual(heights[0], heights[2], "Returning to the narrow pane must restore its measured plan")
        XCTAssertTrue(try f.commands().isEmpty)
        await f.close()
    }

    func testLargeHistoryRepaintAndSingleRowEditReuseCurrentPlans() throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        _ = NSApplication.shared
        let builder = ChatTimelineSnapshotBuilder(), engine = ChatTimelineLayout()
        let coordinator = NativeChatTimelineCoordinator(layout: engine)
        defer { coordinator.dispose() }
        // The builder adds a day separator and the two content insets.
        var messages = (0..<1_997).map { (index: Int) in F.message("m-\(index)", seq: index) }
        let initial = builder.build(F.input(messages: messages.map { F.content($0) }))
        XCTAssertEqual(initial.rows.count, 2_000)
        XCTAssertTrue(coordinator.update(initial, width: 760))
        func requestHeights() {
            for index in coordinator.rows.indices {
                _ = coordinator.tableView(coordinator.tableView, heightOfRow: index)
            }
        }
        requestHeights()
        XCTAssertEqual(coordinator.plans.count, 2_000)
        XCTAssertGreaterThan(engine.measurementCount, engine.heights.entryLimit)
        let originalPlans = coordinator.plans
        let beforeSelection = engine.measurementCount
        let visuals = messages.indices.map { F.visual(selected: $0 == 0) }
        let selected = builder.build(F.input(messages: messages.map { F.content($0) }, visuals: visuals))
        XCTAssertTrue(coordinator.update(selected, width: 760))
        requestHeights()
        let selectionMeasurements = engine.measurementCount - beforeSelection
        XCTAssertEqual(selectionMeasurements, 0, "A repaint must reuse plans even after LRU eviction")
        XCTAssertEqual(coordinator.plans, originalPlans)
        XCTAssertEqual(coordinator.snapshot, selected)

        messages[0].text = String(repeating: "Changed text that wraps onto more lines. ", count: 20)
        messages[0].revision += 1
        let edited = builder.build(F.input(messages: messages.map { F.content($0) }, visuals: visuals))
        let changedID = try XCTUnwrap(edited.rows.first { $0.messageID == "m-0" }).id
        let beforeEdit = engine.measurementCount
        XCTAssertTrue(coordinator.update(edited, width: 760))
        requestHeights()
        let editMeasurements = engine.measurementCount - beforeEdit
        XCTAssertEqual(editMeasurements, 1, "Only the edited row needs TextKit measurement")
        XCTAssertEqual(Set(coordinator.plans.keys.filter { coordinator.plans[$0] != originalPlans[$0] }), [changedID])
        XCTAssertGreaterThan(try XCTUnwrap(coordinator.plans[changedID]).height, try XCTUnwrap(originalPlans[changedID]).height)
        XCTAssertEqual(coordinator.snapshot, edited)
        XCTAssertEqual(coordinator.fullReloads, 1)
        XCTAssertLessThanOrEqual(engine.heights.count, engine.heights.entryLimit)
        XCTAssertLessThanOrEqual(engine.heights.cost, engine.heights.costLimit)
        XCTAssertLessThanOrEqual(engine.contents.count, engine.contents.entryLimit)
        XCTAssertLessThanOrEqual(engine.contents.cost, engine.contents.costLimit)
        print("W02 2000-row TextKit measurements: selection=\(selectionMeasurements), single-row edit=\(editMeasurements)")
    }

    func testPreparationDefersMeasurementsUntilTableRequestsHeights() throws {
        let builder = ChatTimelineSnapshotBuilder(), engine = ChatTimelineLayout()
        let coordinator = NativeChatTimelineCoordinator(layout: engine)
        defer { coordinator.dispose() }
        let snapshot = builder.build(F.input(messages: (0..<1_997).map { (index: Int) in F.content(F.message("m-\(index)", seq: index)) }))
        let prepared = try XCTUnwrap(coordinator.prepare(try XCTUnwrap(coordinator.begin(snapshot, width: 760))))
        XCTAssertEqual(snapshot.rows.count, 2_000)
        XCTAssertEqual(engine.measurementCount, 0, "Preparing a large history must not eagerly measure TextKit rows")
        XCTAssertTrue(prepared.plans.isEmpty)
    }

    func testBoundedCachesEvictLeastRecentlyUsedAndRejectOversizedContent() throws {
        let cache = ChatTimelineCache<String>(entries: 2, bytes: 10)
        let a = key("a"), b = key("b"), c = key("c")
        cache.insert("A", for: a, cost: 4); cache.insert("B", for: b, cost: 4)
        XCTAssertEqual(cache.value(for: a), "A")
        cache.insert("C", for: c, cost: 4)
        XCTAssertEqual(cache.count, 2); XCTAssertEqual(cache.cost, 8)
        XCTAssertNil(cache.value(for: b)); XCTAssertEqual(cache.value(for: a), "A"); XCTAssertEqual(cache.value(for: c), "C")
        cache.insert("replacement", for: a, cost: 8)
        XCTAssertEqual(cache.count, 1); XCTAssertEqual(cache.cost, 8)
        XCTAssertNil(cache.value(for: c))
        cache.insert("oversized", for: a, cost: 11)
        XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.cost, 0)
        cache.insert("C", for: c, cost: 4)
        cache.retain(ids: [a.id], epoch: F.epoch)
        XCTAssertEqual(cache.count, 0)
        cache.insert("A", for: a, cost: 4)
        cache.retain(ids: [a.id], epoch: F.otherEpoch)
        XCTAssertEqual(cache.count, 0); XCTAssertEqual(cache.cost, 0)
    }

    func testWidthRevisionAndEpochKeysAndOnePlanDriveVisibleTextGeometry() throws {
        guard APQuietIsEnabled() else { throw NSError(domain: "Quiet harness required", code: 1) }
        _ = NSApplication.shared
        let engine = ChatTimelineLayout(), builder = ChatTimelineSnapshotBuilder()
        var message = F.message("a"); message.text = String(repeating: "Variable width native text wraps. ", count: 8)
        let snapshot = builder.build(F.input(messages: [F.content(message)]))
        let row = try XCTUnwrap(snapshot.rows.first { $0.messageID == "a" })
        let narrow = ChatTimelineWidth(300.6, scale: 2), wide = ChatTimelineWidth(760, scale: 2)
        XCTAssertEqual(narrow.points, 300.5)
        XCTAssertEqual(narrow, ChatTimelineWidth(300.9, scale: 2))
        XCTAssertNotEqual(narrow, ChatTimelineWidth(301, scale: 2))
        let one = engine.plan(row, snapshot: snapshot, width: narrow)
        XCTAssertEqual(engine.plan(row, snapshot: snapshot, width: ChatTimelineWidth(300.9, scale: 2)), one)
        XCTAssertEqual(engine.heights.misses, 1); XCTAssertEqual(engine.heights.hits, 1)
        let two = engine.plan(row, snapshot: snapshot, width: wide)
        XCTAssertGreaterThan(one.height, two.height)
        XCTAssertEqual(one.body.width, 208.5)
        let cell = ChatNativeShellCell(kind: .message)
        cell.frame = CGRect(x: 0, y: 0, width: narrow.points, height: one.height)
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: one, content: engine.content(row, snapshot: snapshot, width: narrow))
        cell.layoutSubtreeIfNeeded()
        let manager = try XCTUnwrap(cell.body.layoutManager), container = try XCTUnwrap(cell.body.textContainer)
        manager.ensureLayout(for: container)
        XCTAssertEqual(cell.body.frame, one.body)
        XCTAssertEqual(ceil(manager.usedRect(for: container).height), one.body.height)

        let selected = builder.build(F.input(messages: [F.content(message)], visuals: [F.visual(selected: true)]))
        let selectedRow = try XCTUnwrap(selected.rows.first { $0.messageID == "a" })
        XCTAssertEqual(engine.plan(selectedRow, snapshot: selected, width: narrow), one)
        XCTAssertEqual(engine.heights.misses, 2, "A repaint reuses geometry")
        message.text += " A content revision."
        let changed = builder.build(F.input(messages: [F.content(message)]))
        _ = engine.plan(try XCTUnwrap(changed.rows.first { $0.messageID == "a" }), snapshot: changed, width: narrow)
        XCTAssertEqual(engine.heights.misses, 3)
        let reset = builder.build(F.input(messages: [F.content(message)], epoch: F.otherEpoch))
        _ = engine.plan(try XCTUnwrap(reset.rows.first { $0.messageID == "a" }), snapshot: reset, width: narrow)
        XCTAssertEqual(engine.heights.misses, 4)
        engine.retain(snapshot: reset)
        XCTAssertEqual(engine.heights.count, 1); XCTAssertEqual(engine.contents.count, 1)
    }

    func testFileLimitChangesReuseContentAndHeightCachesWhileGeometryInvalidates() throws {
        let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
        var changedLimits = limits; changedLimits.fileBytes += 1; changedLimits.downloadsPerAccount += 1
        let builder = ChatTimelineSnapshotBuilder(), engine = ChatTimelineLayout()
        var message = F.message("file")
        message.attachments = [.init(attachmentId: "document", position: 0, name: "notes.txt", mime: "text/plain", size: 120, hasPreview: false)]
        func capture(_ limits: ChatAttachmentLimits?, available: Bool = true) -> NativeTimelineSnapshot {
            let original = F.content(message)
            let content = NativeTimelineSnapshot.MessageContent(message: original.message, author: original.author,
                authorTooltip: original.authorTooltip, addresses: original.addresses, replyToText: original.replyToText,
                replySummary: original.replySummary, replyCount: original.replyCount, unreadReplyCount: original.unreadReplyCount,
                requestCount: original.requestCount, editing: original.editing, confirmation: original.confirmation,
                actions: original.actions, metadata: original.metadata, sources: original.sources, membershipHints: original.membershipHints,
                attachments: .init(limits: limits, available: available, availableFileIDs: available ? ["document"] : [], pauseReason: nil))
            return builder.build(F.input(messages: [content]))
        }
        let initial = capture(limits), width = ChatTimelineWidth(760, scale: 2)
        let firstRow = try XCTUnwrap(initial.rows.first { $0.messageID == "file" })
        let plan = engine.plan(firstRow, snapshot: initial, width: width)
        _ = engine.content(firstRow, snapshot: initial, width: width)
        let revised = capture(changedLimits)
        let nextRow = try XCTUnwrap(revised.rows.first { $0.messageID == "file" })
        XCTAssertEqual(engine.plan(nextRow, snapshot: revised, width: width), plan)
        _ = engine.content(nextRow, snapshot: revised, width: width)
        XCTAssertEqual(engine.heights.misses, 1); XCTAssertEqual(engine.contents.misses, 1)
        let removed = capture(nil, available: false)
        let removedRow = try XCTUnwrap(removed.rows.first { $0.messageID == "file" })
        _ = engine.plan(removedRow, snapshot: removed, width: width)
        XCTAssertEqual(engine.heights.misses, 2)
        message.attachments[0].name = "A changed document filename.txt"
        let renamed = capture(limits)
        _ = engine.plan(try XCTUnwrap(renamed.rows.first { $0.messageID == "file" }), snapshot: renamed, width: width)
        XCTAssertEqual(engine.heights.misses, 3)
    }

    func testPaginationAndRepeatedWidthsPlateauWithinBothCacheBudgets() throws {
        let engine = ChatTimelineLayout(entryLimit: 12, contentBytes: 8_192, layoutBytes: 2_048)
        let builder = ChatTimelineSnapshotBuilder()
        for page in 0..<10 {
            let snapshot = builder.build(F.input(messages: (0..<20).map { (index: Int) in F.content(F.message("\(page)-\(index)", seq: index)) }))
            for points in [420.0, 760, 420.5] {
                let width = ChatTimelineWidth(points, scale: 2)
                for row in snapshot.rows {
                    _ = engine.plan(row, snapshot: snapshot, width: width)
                    _ = engine.content(row, snapshot: snapshot, width: width)
                }
                engine.retain(snapshot: snapshot)
                XCTAssertLessThanOrEqual(engine.heights.count, 8)
                XCTAssertLessThanOrEqual(engine.heights.cost, 2_048)
                XCTAssertLessThanOrEqual(engine.contents.count, 12)
                XCTAssertLessThanOrEqual(engine.contents.cost, 8_192)
            }
        }
        engine.removeAll()
        XCTAssertEqual(engine.heights.count, 0); XCTAssertEqual(engine.contents.count, 0)
        XCTAssertEqual(engine.heights.cost, 0); XCTAssertEqual(engine.contents.cost, 0)
    }

    private func key(_ id: String) -> ChatTimelineCacheKey {
        .init(id: .init(conversation: F.conversation(), kind: .message(id)), epoch: F.epoch,
              width: ChatTimelineWidth(760, scale: 2), revision: 1)
    }
}
