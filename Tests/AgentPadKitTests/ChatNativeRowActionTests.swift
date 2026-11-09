import AppKit
import AgentPadQuietTestSupport
import GRDB
import XCTest
@testable import AgentPadKit

/// Real offline models and command queues, inside the same quiet native window
/// containment used by the scroll and reference suites. No benchmark action stubs.
@MainActor final class ChatNativeRowActionTests: XCTestCase {
    private var fixtures: [ChatNativeActionFixture] = []
    override func tearDown() async throws {
        for fixture in fixtures.reversed() { await fixture.close() }
        fixtures.removeAll()
    }
    private func fixture(count: Int = 1) async throws -> ChatNativeActionFixture {
        let result = try await ChatNativeActionFixture(count: count)
        fixtures.append(result)
        return result
    }
    func testAttachedEditorSurvivesOffscreenReuseIMEUndoSelectionAndExternalFocus() async throws {
        let f = try await fixture(count: 45)
        defer { f.dispose() }
        try await f.settle()
        let id = f.messages[3].id
        let row = try f.row(id)
        row.rowActions.hover(true)
        try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Edit message" }).performClick(nil)
        try await f.settle()
        let session = try XCTUnwrap(f.coordinator.editorSession), editor = session.editor
        XCTAssertTrue(editor.window === f.host.window)
        XCTAssertTrue(editor.superview === session.host.scroll.contentView)
        XCTAssertTrue(session.host.superview === f.coordinator.editorLayer)
        XCTAssertTrue(f.host.window.firstResponder === editor)
        let original = editor.string
        session.undo.groupsByEvent = false
        session.undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.insertText("Changed", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        session.undo.endUndoGrouping()
        XCTAssertTrue(session.undo.canUndo)
        let typed = editor.string
        session.undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.setMarkedText("入力", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let marked = editor.markedRange(), selection = editor.selectedRange()
        let reused = f.coordinator.cellsReused
        f.coordinator.scrollController.stopFollowing()
        f.coordinator.scrollController.scrollTo(messageID: f.messages.last!.id, alignment: .center)
        try await f.settle()
        XCTAssertNil(f.coordinator.tableView.view(atColumn: 0, row: try XCTUnwrap(f.coordinator.messageIndex(id)), makeIfNecessary: false))
        XCTAssertGreaterThan(f.coordinator.cellsReused, reused)
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertTrue(editor.window === f.host.window, "Retaining a detached NSTextView is not sufficient")
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
        let clip = f.coordinator.scrollView.contentView
        let editorInClip = session.host.convert(session.host.bounds, to: clip)
        XCTAssertFalse(editorInClip.intersects(clip.bounds),
            "Editor must remain outside the viewport after row reuse: editor=\(editorInClip), viewport=\(clip.bounds), visibleRect=\(session.host.visibleRect)")
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(f.host.window.firstResponder === editor)
        // Update the actual input client while its row is still evicted.
        editor.setMarkedText("入力中", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.markedRange())
        try await f.settle()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual((editor.string as NSString).substring(with: editor.markedRange()), "入力中")
        let offscreenMarked = editor.markedRange(), offscreenSelection = editor.selectedRange()
        XCTAssertNil(f.coordinator.tableView.view(atColumn: 0, row: try XCTUnwrap(f.coordinator.messageIndex(id)), makeIfNecessary: false))
        XCTAssertFalse(session.host.convert(session.host.bounds, to: clip).intersects(clip.bounds))
        f.coordinator.scrollController.scrollTo(messageID: id, alignment: .center)
        try await f.settle()
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.markedRange(), offscreenMarked)
        XCTAssertEqual(editor.selectedRange(), offscreenSelection)
        editor.insertText("入力完了", replacementRange: editor.markedRange())
        editor.breakUndoCoalescing()
        session.undo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, (typed as NSString).replacingCharacters(in: NSRange(location: 7, length: 0), with: "入力完了"))
        XCTAssertEqual(f.model.editing?.text, editor.string)
        session.undo.undo()
        XCTAssertEqual(editor.string, typed)
        XCTAssertTrue(session.undo.canUndo, "The edit made before eviction must remain in undo history")
        session.undo.undo()
        XCTAssertEqual(editor.string, original, "Undo must reverse the replacement made before eviction")
        XCTAssertEqual(f.model.editing?.text, original)
        let other = NSTextField(string: "Another control")
        other.frame = CGRect(x: 2, y: 2, width: 160, height: 22); f.view.addSubview(other)
        XCTAssertTrue(f.host.window.makeFirstResponder(other))
        let responder = f.host.window.firstResponder
        f.coordinator.scrollController.scrollTo(messageID: f.messages.last!.id, alignment: .center)
        try await f.settle()
        f.coordinator.scrollController.scrollTo(messageID: id, alignment: .center)
        try await f.settle()
        XCTAssertTrue(f.host.window.firstResponder === responder)
        f.model.cancelEditing(); try await f.settle()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(editor.window)
        XCTAssertTrue(f.host.window.firstResponder === responder, "Model edit end must not steal another control's focus")
        XCTAssertEqual(try f.commands().count, 0)
        await f.close()
    }

    func testRejectedSaveAndFailedCancelRetainTheActualEditorAndProblem() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        let editor = session.editor
        editor.selectAll(nil); editor.insertText("   ", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        session.host.save.performClick(nil); try await f.settle()
        XCTAssertEqual(f.model.editing?.problem, "Write something first.")
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertTrue(session.undo.canUndo)
        XCTAssertEqual(session.host.problem.text.string, "Write something first.")
        // Fixture-only storage fault at the real version-guarded removal.
        try f.base.write("CREATE TEMP TRIGGER refuse_cancel BEFORE DELETE ON edit_drafts BEGIN SELECT RAISE(ABORT, 'fixture storage unavailable'); END")
        session.host.cancel.performClick(nil); try await f.settle()
        XCTAssertNotNil(f.model.editing)
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertTrue(editor.window === f.host.window)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(session.host.problem.text.string, "Write something first.")
        XCTAssertEqual(try f.commands().count, 0)
        try f.base.write("DROP TRIGGER refuse_cancel")
        session.host.cancel.performClick(nil); try await f.settle()
        XCTAssertNil(f.model.editing); XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(editor.window)
        XCTAssertEqual(try f.commands().count, 0)
        await f.close()
    }

    func testAcceptedSaveWithVersionRacedFinishKeepsSessionAndRebindsDraft() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession), editor = session.editor
        editor.selectAll(nil); editor.insertText("Saved through the real service @anna", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        let version = f.model.editing?.version
        // Represents a second window's newer durable version winning removal.
        // It changes only the temporary fixture database, never product schema.
        try f.base.write("""
            CREATE TEMP TRIGGER raced_finish BEFORE DELETE ON edit_drafts BEGIN
                UPDATE edit_drafts SET version = 'newer-window-version' WHERE message_id = OLD.message_id;
                SELECT RAISE(IGNORE);
            END
            """)
        session.host.save.performClick(nil); try await f.settle()
        XCTAssertEqual(try f.commands().map(\.type), ["message.edit"])
        XCTAssertNotEqual(f.model.editing?.version, version)
        XCTAssertEqual(f.model.editing?.version, "newer-window-version")
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertEqual(session.draft, f.model.editing)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertTrue(session.undo.canUndo)
        XCTAssertTrue(editor.window === f.host.window)
        XCTAssertFalse(session.host.save.isEnabled, "The real queued change owns the busy guard")
        try f.base.write("DROP TRIGGER raced_finish")
        session.host.cancel.performClick(nil); try await f.settle()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertEqual(try f.commands().map(\.type), ["message.edit"], "UI disposal must not issue a second command")
        await f.close()
    }

    func testArchiveDeletionAndAccessRevocationUseDomainEditLifetime() async throws {
        let f = try await fixture(count: 3)
        defer { f.dispose() }
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        try f.base.write("UPDATE channels SET archived = 1")
        try await f.settle()
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertFalse(session.host.save.isEnabled)
        XCTAssertEqual(session.host.readOnly.text.string, "Archived: it can't be changed")
        try f.base.write("UPDATE messages SET deleted_at = '2026-10-26T12:00:00Z' WHERE message_id = ?", [f.messages[0].id])
        try await f.settle()
        XCTAssertNil(f.model.editing); XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(session.editor.window)
        try f.base.write("UPDATE channels SET archived = 0")
        try await f.settle(); try await f.edit(index: 1)
        let second = try XCTUnwrap(f.coordinator.editorSession)
        f.view.isHidden = true; try await f.settle()
        XCTAssertTrue(f.coordinator.editorSession === second, "Hiding a mounted pane is not disposal")
        XCTAssertTrue(second.editor.window === f.host.window)
        f.view.isHidden = false; try await f.settle()
        let other = NSTextField(string: "Another control")
        other.frame = CGRect(x: 2, y: 2, width: 160, height: 22); f.view.addSubview(other)
        XCTAssertTrue(f.host.window.makeFirstResponder(other))
        let responder = f.host.window.firstResponder
        let team = try await f.base.store.queue.read { try XCTUnwrap(String.fetchOne($0, sql: "SELECT team_id FROM channels LIMIT 1")) }
        try await f.base.store.queue.write { try ChatStore.leftTeam($0, team) }
        try await f.settle()
        XCTAssertNil(f.model.editing, "Definitive access loss disposes durable state through existing model policy")
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(second.editor.window)
        XCTAssertTrue(f.host.window.firstResponder === responder)
        XCTAssertEqual(try f.commands().count, 0)
        await f.close()
    }

    func testSameContainerReattachesWithFreshEditorAndWorkingRows() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.edit()
        let old = try XCTUnwrap(f.coordinator.editorSession)
        let draft = try XCTUnwrap(f.model.editing)
        let count = f.coordinator.rows.count
        f.host.window.contentView = NSView()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(old.editor.window)
        XCTAssertEqual(f.model.editing, draft)
        f.update()
        XCTAssertNil(f.coordinator.editorSession, "Detached updates must not park an editor")

        let mounted = ChatQuietHost(view: f.view, dark: false, width: 760, height: 400)
        defer { mounted.close() }
        try await mounted.settle()
        XCTAssertTrue(f.coordinator.tableView.delegate === f.coordinator)
        XCTAssertTrue(f.coordinator.tableView.dataSource === f.coordinator)
        XCTAssertEqual(f.coordinator.rows.count, count)
        let reopened = try XCTUnwrap(f.coordinator.editorSession)
        XCTAssertFalse(reopened === old)
        XCTAssertTrue(reopened.editor.window === mounted.window)
        XCTAssertEqual(reopened.editor.string, draft.text)
        XCTAssertEqual(reopened.editor.selectedRange(), NSRange(location: (draft.text as NSString).length, length: 0))
        XCTAssertTrue(mounted.window.firstResponder === reopened.editor)
        XCTAssertTrue(try f.commands().isEmpty)

        reopened.cancel()
        try await f.settle()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(f.model.editing)
        let id = f.messages[0].id
        try f.base.write("UPDATE messages SET text = 'Updated after pane transfer', revision = 4 WHERE message_id = ?", [id])
        try await f.settle()
        let cell = try f.row(id)
        XCTAssertEqual(cell.body.string, "Updated after pane transfer")
        cell.rowActions.hover(true)
        try XCTUnwrap(cell.rowActions.toolbar.buttons.first { $0.title == "Edit message" }).performClick(nil)
        try await f.settle()
        XCTAssertEqual(f.model.editing?.text, "Updated after pane transfer")
        XCTAssertTrue(f.coordinator.editorSession?.editor.window === mounted.window)
        XCTAssertTrue(try f.commands().isEmpty)
    }

    func testRetainedDraftRemountFocusesOnceWhenPreparedBeforeWindowAttachment() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.edit()
        let old = try XCTUnwrap(f.coordinator.editorSession)
        old.editor.selectAll(nil)
        old.editor.insertText("A retained draft 👩🏽‍💻", replacementRange: old.editor.selectedRange())
        try await f.settle()
        old.editor.setSelectedRange(NSRange(location: 0, length: 2))
        let draft = try XCTUnwrap(f.model.editing)
        f.host.window.contentView = NSView()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(old.editor.window)
        XCTAssertEqual(f.model.editing, draft)

        let adapter = ChatTimelineAdapter()
        defer { adapter.invalidate() }
        func snapshot() -> NativeTimelineSnapshot {
            adapter.snapshot(model: f.model, root: nil, members: [], mentionable: [],
                me: f.base.key.accountId, archived: false, ownerModel: nil,
                style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                    increasedContrast: false, alwaysShowTime: false))
        }
        let coordinator = NativeChatTimelineCoordinator()
        defer { coordinator.dispose() }
        let container = NativeChatTimelineContainer(coordinator: coordinator)
        container.frame = CGRect(x: 0, y: 0, width: 760, height: 400)
        let prepared = snapshot()
        coordinator.actions = adapter.actions
        container.update(prepared)
        let reopened = try XCTUnwrap(coordinator.editorSession)
        XCTAssertFalse(reopened === old)
        XCTAssertNil(container.window)
        XCTAssertNil(reopened.editor.window)
        XCTAssertTrue(reopened.host.superview === coordinator.editorLayer)
        XCTAssertEqual(reopened.editor.string, draft.text)
        XCTAssertEqual(reopened.editor.selectedRange(), NSRange(location: (draft.text as NSString).length, length: 0))

        let mounted = ChatQuietHost(view: container, dark: false, width: 760, height: 400)
        defer { mounted.close() }
        try await mounted.settle()
        XCTAssertTrue(reopened.editor.window === mounted.window)
        XCTAssertTrue(mounted.window.firstResponder === reopened.editor)
        XCTAssertEqual(reopened.editor.selectedRange(), NSRange(location: (draft.text as NSString).length, length: 0))
        let other = NSTextField(string: "Another control")
        other.frame = CGRect(x: 2, y: 2, width: 160, height: 22)
        container.addSubview(other)
        XCTAssertTrue(mounted.window.makeFirstResponder(other))
        let responder = mounted.window.firstResponder
        container.update(snapshot())
        container.setFrameSize(NSSize(width: 720, height: 400))
        container.layoutSubtreeIfNeeded()
        try await mounted.settle()
        XCTAssertTrue(coordinator.editorSession === reopened)
        XCTAssertTrue(mounted.window.firstResponder === responder)
        XCTAssertEqual(f.model.editing, draft)
        XCTAssertTrue(try f.commands().isEmpty)
    }

    func testActualPaneUnmountDisposesOnlyPresentationAndNoCommands() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        session.editor.insertText(" survives remount", replacementRange: session.editor.selectedRange())
        let draft = f.model.editing
        f.host.window.contentView = NSView()
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(session.editor.window)
        XCTAssertEqual(f.model.editing, draft)
        XCTAssertEqual(try f.commands().count, 0)
        session.save(); session.cancel()
        XCTAssertEqual(f.model.editing, draft, "Disposed callbacks cannot cancel or save the retained domain draft")
        XCTAssertEqual(try f.commands().count, 0)
        await f.close()
    }

    func testSaveEndsAuthoritativeEditAndOldToolbarCannotActAfterReuse() async throws {
        let f = try await fixture(count: 2)
        defer { f.dispose() }
        try await f.settle()
        let row = try f.row(f.messages[0].id)
        let oldReply = try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Reply in thread" })
        try await f.edit()
        let session = try XCTUnwrap(f.coordinator.editorSession)
        session.editor.selectAll(nil)
        session.editor.insertText("A new draft @anna", replacementRange: session.editor.selectedRange())
        session.host.save.performClick(nil); try await f.settle()
        XCTAssertNil(f.model.editing); XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(session.editor.window)
        let commands = try f.commands()
        XCTAssertEqual(commands.map(\.type), ["message.edit"])
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first))["text"]?.string, "A new draft @anna")
        row.unbind()
        oldReply.performClick(nil)
        XCTAssertNil(f.model.threadRoot, "A detached toolbar callback cannot target the next bound row")
        session.save(); session.cancel()
        XCTAssertEqual(try f.commands().count, 1)
        await f.close()
    }

    func testMenusResolveCurrentCopyRevisionAndRealDeleteConfirmation() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        try await f.settle()
        let id = f.messages[0].id, cell = try f.row(f.messages[0].id)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        cell.rowActions.pasteboard = board
        let menu = try XCTUnwrap(cell.rowActions.makeMenu())
        XCTAssertEqual(menu.items.map(\.title), ["Reply in Thread", "Open as tab", "Copy message link", "Always show time", "Copy text", "Edit", "Delete…"])
        try f.base.write("UPDATE messages SET text = 'Fresh current text', revision = 4 WHERE message_id = ?", [id])
        try await Task.sleep(for: .milliseconds(80))
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Copy text" }))
        XCTAssertEqual(board.string(forType: .string), "Fresh current text")
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Delete…" }))
        XCTAssertFalse(f.confirmation.showsBlock, "A stale displayed revision cannot request deletion")
        try await f.settle()
        let fresh = try XCTUnwrap(cell.rowActions.makeMenu())
        fresh.performActionForItem(at: try XCTUnwrap(fresh.items.firstIndex { $0.title == "Delete…" }))
        try await f.settle()
        XCTAssertEqual(f.confirmation.phase, .awaiting)
        XCTAssertTrue(f.confirmation.isVisible)
        let native = try f.row(id).inlineControls.confirmation
        XCTAssertTrue(f.host.window.firstResponder === native.cancel)
        XCTAssertEqual(native.accessibilityIdentifier(), "inline-confirmation")
        native.accept.performClick(nil)
        try await f.settle()
        XCTAssertEqual(try f.commands().map(\.type), ["message.delete"])
        XCTAssertEqual(f.confirmation.phase, .completed)
        await f.close()
    }
}

@MainActor final class ChatNativeActionFixture {
    let directory: URL
    let scope = TeamServiceTestScope()
    let base: ChatChannelExecutionTests.Fixture
    let model: ChatChannelModel
    let confirmation = ConfirmationCoordinator()
    let adapter = ChatTimelineAdapter()
    let coordinator = NativeChatTimelineCoordinator()
    let view: NativeChatTimelineContainer
    let host: ChatQuietHost
    let messages: [ChatMessage]
    private var closed = false
    init(count: Int = 1, width: CGFloat = 760, dark: Bool = false) async throws {
        XCTAssertTrue(APQuietIsEnabled())
        ChatScrollAppKitSettings.install(); AgentPadFonts.registerOnce(); _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-actions-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let base = try await ChatChannelExecutionTests.Fixture(root: directory)
        self.base = base
        let messages = try (0..<count).map { index in
            try ChatTimelineReferenceFixture.message(UUID().uuidString.lowercased(), me: base.key.accountId,
                text: "Text \(index) keeps its native selection and undo.\nAnother line for the scroll fixture.", seq: index + 1)
        }
        self.messages = messages
        try await base.store.queue.write { db in
            for message in messages {
                try db.execute(sql: """
                    INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                    VALUES (?, ?, ?, ?, ?, 1, 1, ?, '[]', 3)
                    """, arguments: [message.id, message.channelId, message.authorAccountId, message.seq, message.createdAt, message.text])
            }
        }
        model = ChatChannelModel(key: base.key, channel: ChatTimelineReferenceFixture.channel)
        model.service = base.service; model.tabID = UUID(); model.confirmation = confirmation
        model.follow(base.store)
        view = NativeChatTimelineContainer(coordinator: coordinator)
        host = ChatQuietHost(view: view, dark: dark, width: width, height: 400)
        ChatScrollAppKitSettings.apply(to: coordinator.scrollView)
        update()
    }
    func update() {
        let snapshot = adapter.snapshot(model: model, root: nil,
            members: [.init(accountId: base.key.accountId, handle: "anna", name: "Anna", role: "owner")],
            mentionable: [(base.key.accountId, "anna")], me: base.key.accountId, archived: model.feed.archived,
            ownerModel: nil, style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false))
        coordinator.actions = adapter.actions; view.update(snapshot)
    }
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(80)); update(); try await host.settle()
    }
    func row(_ id: String) throws -> ChatNativeShellCell {
        coordinator.scrollController.scrollTo(messageID: id, alignment: .center)
        view.layoutSubtreeIfNeeded()
        return try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: try XCTUnwrap(coordinator.messageIndex(id)), makeIfNecessary: true) as? ChatNativeShellCell)
    }
    func edit(index: Int = 0) async throws {
        try await settle()
        let row = try row(messages[index].id)
        row.rowActions.hover(true)
        try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Edit message" }).performClick(nil)
        try await settle()
        XCTAssertEqual(model.editing?.messageId, messages[index].id)
    }
    func commands() throws -> [ChatCommandRecord] { try base.commands().filter { ["message.edit", "message.delete", "message.post"].contains($0.type) } }
    func dispose() { coordinator.dispose(); adapter.invalidate(); host.close() }
    func close() async {
        guard !closed else { return }; closed = true
        dispose(); base.sender?.hold(); await base.service.disconnect()
        scope.close(); ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: directory)
        XCTAssertNil(APQuietFailure())
    }
}
