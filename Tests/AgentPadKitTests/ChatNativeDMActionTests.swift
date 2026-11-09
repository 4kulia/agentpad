import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatNativeDMActionTests: XCTestCase {
    private var fixture: ChatNativeActionFixture?
    private var model: ChatDMModel?
    private var socket: ChatSocket?
    private var sync: ChatDMSync?
    private let dm = "2c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"

    override func tearDown() async throws {
        model?.stop(); sync?.stop(); socket?.stop()
        if let fixture { await fixture.close() }
        model = nil; sync = nil; socket = nil; fixture = nil
    }

    private func setupDM() async throws -> (ChatNativeActionFixture, ChatDMModel) {
        let f = try await ChatNativeActionFixture()
        fixture = f
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/dms_response.json")
        let catalog = try Data(contentsOf: url)
        ChatStubProtocol.reset { request, _ in
            if request.url?.path.hasSuffix("/dms") == true { return .success(.init(status: 200, body: catalog)) }
            return .failure(URLError(.unsupportedURL))
        }
        let transport = FakeSocketTransport()
        let socket = ChatSocket(server: f.base.key.server, token: "test-only", makeTransport: { transport })
        self.socket = socket // Never start this fixture's socket.
        let owner = ChatSync(key: f.base.key, store: f.base.store,
            api: ChatAPI(server: f.base.key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: socket, outbox: nil, token: "test-only")
        f.base.service.orgSessions[f.base.key]?.sync = owner
        sync = owner.dm
        owner.dm.sessionId = "s-anna"
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.dm"]
        owner.dm.configure(true)
        try await owner.dm.reloadCatalog(valid: { true })
        let model = ChatDMModel(key: f.base.key, dm: dm, service: f.base.service)
        self.model = model
        try await settle(f, model)
        XCTAssertTrue(model.readable)
        XCTAssertEqual(model.feed.messages.count, 1)
        return (f, model)
    }

    private func settle(_ f: ChatNativeActionFixture, _ model: ChatDMModel, root: String? = nil) async throws {
        try await Task.sleep(for: .milliseconds(80))
        let snapshot = f.adapter.snapshot(model: model, root: root, members: [], mentionable: [],
            me: f.base.key.accountId, archived: model.feed.archived, ownerModel: nil,
            style: ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
                increasedContrast: false, alwaysShowTime: false))
        f.coordinator.actions = f.adapter.actions
        f.view.update(snapshot)
        try await f.host.settle()
    }

    func testW08NativeDMReadRequiresLoadedThreadAndCurrentAccessEpoch() async throws {
        let previous = ChatNotifications.appActive
        ChatNotifications.appActive = { false }
        defer { ChatNotifications.appActive = previous }
        let (f, model) = try await setupDM()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/dm_message.json")
        var root = try JSONDecoder().decode(ChatDMMessageWire.self, from: Data(contentsOf: url))
        root.messageId = "w08-root"; root.seq = 3; root.authorAccountId = CallJSON.boris
        var reply = root
        reply.messageId = "w08-reply"; reply.seq = 4; reply.threadRootId = root.messageId
        let rootWire = root, replyWire = reply
        try await f.base.store.queue.write { db in
            try ChatDMStore.write(db, rootWire); try ChatDMStore.write(db, replyWire)
            try db.execute(sql: "UPDATE dm_marks SET seq = 0")
        }
        func mark(_ root: String? = nil) throws -> Int {
            try f.base.store.dmRead { try ChatDMStore.mark($0, self.dm, root: root) }
        }
        try await settle(f, model)
        ChatNotifications.appActive = { true }
        f.coordinator.scrollController.followBottom()
        try await settle(f, model)
        XCTAssertEqual(try mark(), 3)
        XCTAssertEqual(try mark(root.messageId), 0)
        model.openThread(root.messageId)
        try await settle(f, model, root: root.messageId)
        f.coordinator.scrollController.followBottom()
        try await settle(f, model, root: root.messageId)
        XCTAssertTrue(model.threadHasEarlier)
        XCTAssertEqual(try mark(root.messageId), 0, "Cached rows alone do not make a DM thread loaded")
        let page = try JSONEncoder().encode(ChatDMMessagesPage(messages: [root, reply], next: nil, head: 4))
        ChatStubProtocol.reset { request, _ in
            if request.url?.path.hasSuffix("/threads/w08-root") == true { return .success(.init(status: 200, body: page)) }
            return .failure(URLError(.unsupportedURL))
        }
        model.earlierReplies()
        try await settle(f, model, root: root.messageId)
        XCTAssertFalse(model.threadHasEarlier)
        XCTAssertEqual(try mark(root.messageId), 4)
        XCTAssertEqual(try mark(), 3, "DM thread reading excludes the root and leaves feed independent")
        let boundary = model.threadUnreadID
        f.view.isHidden = true
        try await f.host.settle()
        XCTAssertEqual(model.threadUnreadID, boundary, "DM endReading retains its frozen boundary")
        let oldActions = try XCTUnwrap(f.adapter.actions)
        sync?.invalidate()
        XCTAssertFalse(model.readable)
        oldActions.readIfLooking(appActive: true, shown: true, atBottom: true)
        f.view.isHidden = false
        try await settle(f, model, root: root.messageId)
        XCTAssertEqual(f.coordinator.snapshot?.messageIDs, [])
        XCTAssertEqual(try mark(root.messageId), 4, "A stale scope cannot advance the DM mark after its epoch is invalidated")
        XCTAssertNil(f.coordinator.editorSession)
    }

    func testW08DMCallersKeepComposerAndSearchRevealWithoutChannelReturnState() async throws {
        let (f, model) = try await setupDM()
        f.coordinator.dispose(); f.adapter.invalidate()
        let card = try XCTUnwrap(model.card), message = try XCTUnwrap(model.feed.messages.first)
        let view = ChatDMView(model: model, card: card)
        let hostingView = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let host = ChatQuietHost(view: hostingView, dark: false, width: 1_100, height: 650)
        defer { host.close() }
        func settle() async throws { for _ in 0..<3 { try await host.settle() } }
        func panes() -> [NativeChatTimelineCoordinator] {
            ChatTimelineReferenceCapture.descendants(host.view, NativeChatTimelineContainer.self).map(\.coordinator)
        }
        try await settle()
        XCTAssertEqual(panes().count, 1)
        XCTAssertEqual(panes().first?.tableView.accessibilityLabel(), "Direct messages")
        model.revealSearchMessage(message, in: model.feed.messages)
        try await settle()
        XCTAssertEqual(panes().first?.scrollController.selectedID, message.id)
        XCTAssertFalse(model.searching); XCTAssertFalse(model.hasNavigationReturn)
        model.finishNavigation()
        XCTAssertEqual(model.revealMessageID, message.id)
        model.openThread(message.id)
        try await settle()
        XCTAssertEqual(panes().count, 2)
        XCTAssertEqual(panes().map { $0.tableView.accessibilityLabel() }.compactMap { $0 }.sorted(), ["Direct messages", "Thread messages"])
        model.focusRequest = ChatFocusRequest(area: .composer)
        try await settle()
        XCTAssertTrue(host.window.firstResponder is ChatMentionEditor.Editor)
        host.window.setContentSize(NSSize(width: 700, height: 650))
        try await settle()
        XCTAssertEqual(panes().count, 1)
        XCTAssertEqual(panes().first?.snapshot?.conversation.root, message.id)
        XCTAssertTrue(model.dismissTransient())
        try await settle()
        XCTAssertNil(model.threadRoot)
        XCTAssertFalse(model.dismissTransient(), "DM Escape has no channel mark-read/search fallback")
        XCTAssertEqual(panes().first?.tableView.accessibilityLabel(), "Direct messages")
        let hosting = try XCTUnwrap(host.view as? NSHostingView<AnyView>)
        let coordinators = panes()
        hosting.rootView = AnyView(EmptyView())
        try await settle()
        XCTAssertTrue(coordinators.allSatisfy { $0.lifecycle.observerCount == 0 && $0.scrollController.inputMonitorCount == 0 })
    }

    private func edit(_ f: ChatNativeActionFixture, _ model: ChatDMModel) async throws -> NativeInlineEditorSession {
        let message = try XCTUnwrap(model.feed.messages.first)
        let row = try f.row(message.id)
        row.rowActions.hover(true)
        try XCTUnwrap(row.rowActions.toolbar.buttons.first { $0.title == "Edit message" }).performClick(nil)
        try await settle(f, model)
        let session = try XCTUnwrap(f.coordinator.editorSession)
        XCTAssertTrue(session.editor.window === f.host.window)
        return session
    }

    func testNativeDMKeepsChannelMetadataRequestsAndMembershipAbsent() async throws {
        let (f, model) = try await setupDM()
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.dm", "chat.reactions", "chat.pins", "chat.thread_summary", "chat.channel_ux1"]
        try await settle(f, model)
        let id = try XCTUnwrap(model.feed.messages.first?.id)
        let cell = try f.row(id)
        let row = try XCTUnwrap(f.coordinator.snapshot?.rows.first { $0.messageID == id })
        guard case .message(let value) = row.payload else { return XCTFail("Missing DM message") }
        XCTAssertNil(value.content.metadata)
        XCTAssertEqual(value.content.sources, [])
        XCTAssertEqual(value.content.membershipHints, [])
        XCTAssertEqual(f.coordinator.rows.filter { if case .legacyRequest = $0.payload { true } else { false } }, [])
        let actions = try XCTUnwrap(f.adapter.actions)
        actions.toggleSources(messageID: id)
        XCTAssertEqual(actions.sourcePresentation(messageID: id), .init())
        XCTAssertNil(actions.reactionContext(messageID: id))
        XCTAssertFalse(actions.perform(.toggleReaction("👍"), messageID: id))
        XCTAssertFalse(actions.perform(.togglePin, messageID: id))
        XCTAssertFalse(actions.performSource(.details, messageID: id, requestID: "request"))
        XCTAssertFalse(actions.addAgent(messageID: id, agentID: CallJSON.agent))
        XCTAssertFalse(actions.openRequest(requestID: "request"))
        XCTAssertTrue(ChatTimelineReferenceCapture.descendants(cell.metadata, NSButton.self)
            .allSatisfy(\.isHiddenOrHasHiddenAncestor))
        XCTAssertTrue(try f.base.commands().isEmpty)
    }

    func testNativeDMRejectedSaveKeepsEditorThenAcceptedSaveQueuesExactDMCommand() async throws {
        let (f, model) = try await setupDM()
        let message = try XCTUnwrap(model.feed.messages.first)
        let session = try await edit(f, model)
        session.editor.selectAll(nil)
        session.editor.insertText("   ", replacementRange: session.editor.selectedRange())
        // Drain the durable draft observation before Save. ChatDMModel.accept
        // adopts stored drafts; a delivery still owed from typing can otherwise
        // replace the transient problem that saveEditing's catch just set.
        try await settle(f, model)
        session.host.save.performClick(nil)
        try await settle(f, model)
        XCTAssertTrue(f.coordinator.editorSession === session)
        XCTAssertEqual(model.editing?.problem, "Chat data: Write something first.")
        XCTAssertEqual(session.host.problem.text.string, model.editing?.problem)
        XCTAssertTrue(try f.base.commands().isEmpty)
        session.editor.selectAll(nil)
        session.editor.insertText("Saved privately through native controls", replacementRange: session.editor.selectedRange())
        session.host.save.performClick(nil)
        try await settle(f, model)
        let commands = try f.base.commands()
        XCTAssertEqual(commands.map(\.type), ["dm.message.edit"])
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first)), ["dm_id": .string(dm),
            "message_id": .string(message.id), "expected_revision": .number(1),
            "text": .string("Saved privately through native controls"), "mentions": .array([])])
        XCTAssertNil(model.editing)
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(session.editor.window)
    }

    func testNativeDMAccessLossDisposesAttachedEditorWithoutCommandsOrFocusTheft() async throws {
        let (f, model) = try await setupDM()
        let session = try await edit(f, model)
        let other = NSTextField(string: "Another control")
        other.frame = CGRect(x: 2, y: 2, width: 160, height: 22)
        f.view.addSubview(other)
        XCTAssertTrue(f.host.window.makeFirstResponder(other))
        let responder = f.host.window.firstResponder
        try XCTUnwrap(sync).invalidate()
        try await settle(f, model)
        XCTAssertFalse(model.readable)
        XCTAssertNil(model.editing)
        XCTAssertNil(f.coordinator.editorSession)
        XCTAssertNil(session.editor.window)
        XCTAssertTrue(f.host.window.firstResponder === responder)
        session.host.save.performClick(nil)
        XCTAssertTrue(try f.base.commands().isEmpty)
    }

    func testNativeDeletedDMStillOffersAndDispatchesReplyInThread() async throws {
        let (f, model) = try await setupDM()
        let message = try XCTUnwrap(model.feed.messages.first)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/dm_message.json")
        var deleted = try JSONDecoder().decode(ChatDMMessageWire.self, from: Data(contentsOf: url))
        deleted.messageId = message.id
        deleted.revision = message.revision + 1
        deleted.deletedAt = "2026-10-26T12:00:00Z"
        deleted.text = ""
        try f.base.store.dmWrite { try ChatDMStore.write($0, deleted) }
        try await settle(f, model)
        XCTAssertTrue(try XCTUnwrap(model.message(message.id)).deleted)
        let menu = try XCTUnwrap(f.row(message.id).rowActions.makeMenu())
        let reply = try XCTUnwrap(menu.items.firstIndex { $0.title == "Reply in Thread" })
        XCTAssertTrue(menu.items[reply].isEnabled)
        XCTAssertFalse(menu.items.contains { ["Edit", "Delete…", "Copy message link"].contains($0.title) })
        menu.performActionForItem(at: reply)
        XCTAssertEqual(model.threadRoot, message.id)
        XCTAssertTrue(try f.base.commands().isEmpty)
    }

    func testEveryDMMenuCommandDispatchesToReusedMessageAndOwningSession() async throws {
        let (f, model) = try await setupDM()
        let source = try XCTUnwrap(model.feed.messages.first)
        var wire = try f.base.store.dmRead { db in
            try JSONDecoder().decode(ChatDMMessageWire.self, from: XCTUnwrap(Data.fetchOne(db,
                sql: "SELECT body FROM dm_messages WHERE message_id = ?", arguments: [source.id])))
        }
        wire.messageId = UUID().uuidString.lowercased(); wire.seq += 1; wire.text = "The reused private message"
        let target = wire
        try f.base.store.dmWrite { try ChatDMStore.write($0, target) }
        let state = TabState(route: .directMessage(ChatDMRef(f.base.key, dm: dm)))
        model.state = state
        let session = Session(engine: TestEngine(), currentDirectory: f.directory, agent: .terminal)
        session.content = .tool(state.route); model.tabID = session.id
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: f.directory.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: f.directory.appendingPathComponent("drafts.json")),
            engineFactory: { XCTFail("No process should launch"); return TestEngine() })
        let oldStores = TabRouter.shared.stores
        TabRouter.shared.stores = { [store] }
        let oldTime = UserDefaults.standard.object(forKey: "chat.ux2.alwaysShowTime")
        defer {
            store.terminate(); TabRouter.shared.stores = oldStores
            UserDefaults.standard.set(oldTime, forKey: "chat.ux2.alwaysShowTime")
        }
        XCTAssertTrue(store.popups.presentConversation(session))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let commands = ["Reply in Thread", "Open as tab", "Always show time", "Copy text", "Edit", "Delete…"]
        for title in commands {
            print("W05 DM menu dispatch after reuse: \(title)")
            model.cancelEditing(); model.openThread(nil); state.confirmation.invalidate()
            UserDefaults.standard.set(false, forKey: "chat.ux2.alwaysShowTime")
            try await settle(f, model)
            let (cell, stale, menu) = try ChatNativeMenuParity.reusedMenu(f, from: source.id, to: target.messageId)
            XCTAssertEqual(menu.items.map(\.title), commands)
            cell.rowActions.pasteboard = board
            board.clearContents(); board.setString("Unchanged", forType: .string)
            for index in stale.items.indices { stale.performActionForItem(at: index) }
            XCTAssertNil(model.threadRoot); XCTAssertNil(model.editing)
            XCTAssertFalse(state.confirmation.showsBlock)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
            XCTAssertEqual(board.string(forType: .string), "Unchanged")
            XCTAssertTrue(try f.base.commands().isEmpty)
            try ChatNativeMenuParity.dispatch(title, in: menu)
            switch title {
            case "Reply in Thread":
                XCTAssertEqual(model.threadRoot, target.messageId)
                XCTAssertTrue(store.popups.isPresented)
            case "Open as tab":
                XCTAssertEqual(model.threadRoot, target.messageId)
                XCTAssertFalse(store.popups.isPresented)
                XCTAssertTrue(store.active?.activeSession === session)
            case "Always show time":
                XCTAssertTrue(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
                try ChatNativeMenuParity.dispatch(title, in: menu)
                XCTAssertFalse(UserDefaults.standard.bool(forKey: "chat.ux2.alwaysShowTime"))
            case "Copy text": XCTAssertEqual(board.string(forType: .string), target.text)
            case "Edit":
                XCTAssertEqual(model.editing?.messageId, target.messageId)
                XCTAssertEqual(model.editing?.text, target.text)
                XCTAssertEqual(model.editing?.revision, target.revision)
                XCTAssertNil(model.editing?.root)
            case "Delete…":
                XCTAssertEqual(state.confirmation.context?.targetID, "message:" + target.messageId)
                try await settle(f, model)
                try f.row(target.messageId).inlineControls.confirmation.accept.performClick(nil)
            default: XCTFail("Unasserted DM command: " + title)
            }
            try await settle(f, model)
            let queued = try f.base.commands()
            XCTAssertEqual(queued.map(\.type), title == "Delete…" ? ["dm.message.delete"] : [], title)
            if title == "Delete…" {
                XCTAssertEqual(ChatService.args(try XCTUnwrap(queued.first)), ["dm_id": .string(dm),
                    "message_id": .string(target.messageId), "expected_revision": .number(Double(target.revision))])
            }
        }
    }
}
