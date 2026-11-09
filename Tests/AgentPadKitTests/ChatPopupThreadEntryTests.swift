import AgentPadQuietTestSupport
@testable import AgentPadTelegram
import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor final class ChatPopupThreadEntryTests: XCTestCase {
    private var scope: TeamServiceTestScope!
    private var fixture: ChatPopupCaptureFixture!
    private var directory: URL!
    private var oldStores: (() -> [WorkspaceStore])!
    private var oldAdmit: ((@escaping () -> Void) -> Bool)?
    private var oldAccessibility: Any?
    private let accessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        XCTAssertTrue(APQuietIsEnabled())
        _ = NSApplication.shared
        oldAccessibility = NSApp.accessibilityAttributeValue(accessibility)
        NSApp.accessibilitySetValue(true, forAttribute: accessibility)
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("popup-thread-actions-\(UUID())")
        do { fixture = try await ChatPopupCaptureFixture(root: directory) }
        catch {
            print("POPUP_THREAD_FAILURE phase=fixture-setup type=\(String(reflecting: type(of: error))) error=\(error)")
            throw error
        }
        oldStores = TabRouter.shared.stores; oldAdmit = TabRouter.shared.admit
        TabRouter.shared.admit = nil
    }

    override func tearDown() async throws {
        TabRouter.shared.stores = oldStores; TabRouter.shared.admit = oldAdmit
        fixture?.close(); fixture = nil
        scope?.close(); scope = nil
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        NSApp.accessibilitySetValue(oldAccessibility, forAttribute: accessibility)
    }

    private func workspace() -> WorkspaceStore {
        WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            drafts: DraftRepository(), engineFactory: { TestEngine() })
    }

    private func conversation(_ backend: String) throws -> (Session, any ChatConversationPresentation, String) {
        let session = try fixture.session(backend == "dm" ? "dm-draft" : "channel")
        if let model = session.tabState?.dmModel {
            model.tabID = session.id
            return (session, model, "popup-dm-0")
        }
        let model = try XCTUnwrap(session.channelConversation?.model)
        model.tabID = session.id
        return (session, model, ChatPopupCaptureFixture.thread)
    }

    private func rowHost(_ model: any ChatConversationPresentation, root: String) throws -> ChatQuietHost {
        let message = try XCTUnwrap(model.message(root))
        return ChatQuietHost(content: AnyView(ChatNativeRowFixture(model: model, message: message,
            members: [], mentionable: [], me: model.key.accountId, archived: false,
            replies: model.feed.replies[root] ?? 0, selected: true).padding(.top, 24)), dark: true, width: 760, height: 260)
    }

    private func withCommandClick(_ host: ChatQuietHost, _ action: () throws -> Void) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 100, y: 100),
            modifierFlags: .command, timestamp: 0, windowNumber: host.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let neutral = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        // Only this process's AppKit queue is used. Dequeuing establishes the
        // real currentEvent; quiet dispatch alone deliberately does not.
        func makeCurrent(_ value: NSEvent) {
            NSApp.postEvent(value, atStart: true)
            let queued = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
            for observed in [queued, NSApp.currentEvent] {
                XCTAssertEqual(observed?.type, value.type)
                XCTAssertEqual(observed?.modifierFlags.intersection(.deviceIndependentFlagsMask),
                    value.modifierFlags.intersection(.deviceIndependentFlagsMask))
                XCTAssertEqual(observed?.windowNumber, value.windowNumber)
            }
        }
        makeCurrent(event)
        defer {
            makeCurrent(neutral)
            XCTAssertFalse(ConversationOpenIntent.commandClick, "Command-click input cannot leak into later routing tests")
        }
        XCTAssertTrue(ConversationOpenIntent.commandClick)
        try action()
    }

    func testReplyButtonsCommandClickPromotesTheSameLocalConversation() async throws {
        for backend in ["channel", "channel-server", "dm"] {
            for control in ["reply", "count"] {
                let owner = workspace(), remote = workspace()
                defer { owner.terminate(); remote.terminate() }
                TabRouter.shared.stores = { [remote, owner] }
                let (session, model, root) = try conversation(backend)
                if backend == "channel-server" {
                    fixture.service.serverCapabilities[model.key.server, default: []].insert("chat.thread_summary")
                    try await fixture.base.store.queue.write { db in
                        try ChatB1.watch(db, channel: ChatPopupCaptureFixture.channel, ids: [root])
                        let metadata = ChatB1.Metadata(messageId: root, deleted: false, reactions: [],
                            threadSummary: .init(rootId: root, replyCount: 10, lastParticipants: []))
                        try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = ?",
                            arguments: [try ChatB1.encode(metadata), root])
                    }
                }
                if backend == "dm" {
                    try fixture.base.store.dmWrite { db in
                        try ChatDMStore.write(db, .init(messageId: "popup-dm-reply", dmId: ChatPopupCaptureFixture.dm,
                            threadRootId: root, authorAccountId: CallJSON.boris, text: "Fictional reply", mentions: [],
                            revision: 1, seq: 4, createdAt: "2026-10-24T10:00:00Z"))
                    }
                }
                XCTAssertTrue(owner.popups.presentConversation(session))
                let savedDraft: String
                if let channel = model as? ChatChannelModel {
                    channel.saveDraft("Fictional channel reply", root: root)
                    channel.revealMessageID = root
                    savedDraft = channel.composerDraft(root: root).text
                } else {
                    let dm = try XCTUnwrap(model as? ChatDMModel)
                    XCTAssertNotNil(dm.saveDraft("Fictional DM reply", root: root))
                    dm.revealMessageID = root
                    savedDraft = try XCTUnwrap(dm.draft(root: root)).text
                }
                var retained = ChatScrollPosition()
                _ = retained.update(model.conversationMessages(root: root), me: model.key.accountId)
                retained.measured(bottom: false, anchor: root)
                model.positions[root] = retained
                let host = try rowHost(model, root: root)
                defer { host.close() }
                try await host.settle()
                let title = control == "reply" ? "Reply in thread" : try XCTUnwrap(host.strings.first { $0.hasSuffix("open thread") })
                if backend == "channel-server", control == "count" { XCTAssertTrue(title.hasPrefix("10 replies")) }
                try withCommandClick(host) { try host.press(title) }
                try await host.settle()
                XCTAssertEqual(model.threadRoot, root)
                XCTAssertFalse(owner.popups.isPresented, "\(backend) \(control)")
                XCTAssertTrue(owner.active?.activeSession === session, "\(backend) \(control)")
                XCTAssertEqual(model.revealMessageID, root)
                XCTAssertEqual(model.positions[root], retained)
                if let channel = model as? ChatChannelModel { XCTAssertEqual(channel.composerDraft(root: root).text, savedDraft) }
                else { XCTAssertEqual((model as? ChatDMModel)?.draft(root: root)?.text, savedDraft) }
                XCTAssertTrue(remote.allSessions.isEmpty)
                XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
            }
        }
    }

    func testReplyButtonOrdinaryClickKeepsThreadInsidePopup() async throws {
        for backend in ["channel", "dm"] {
            let owner = workspace(); defer { owner.terminate() }
            TabRouter.shared.stores = { [owner] }
            let (session, model, root) = try conversation(backend)
            XCTAssertTrue(owner.popups.presentConversation(session))
            let host = try rowHost(model, root: root); defer { host.close() }
            try await host.settle(); try host.press("Reply in thread"); try await host.settle()
            XCTAssertEqual(model.threadRoot, root)
            XCTAssertTrue(owner.popups.visibleConversation === session)
            XCTAssertTrue(owner.allSessions.isEmpty)
        }
    }

    private func contextMenu(_ host: ChatQuietHost, title selectedTitle: String? = nil) throws -> NSMenu {
        // Materialize the production context menu without starting menu tracking.
        if let cell = ChatTimelineReferenceCapture.descendants(host.view, ChatNativeShellCell.self).first {
            return try XCTUnwrap(cell.rowActions.makeMenu(), "The native row must supply its production context menu")
        }
        let title = selectedTitle ?? host.strings.first { $0.hasPrefix("Fictional topic,") } ?? "Reply in thread"
        let control = try host.control(title), selector = NSSelectorFromString("accessibilityFrame")
        XCTAssertTrue(control.responds(to: selector))
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        let frame = unsafeBitCast(control.method(for: selector), to: Frame.self)(control, selector)
        let location = host.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: location, modifierFlags: [], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        var view = host.view.hitTest(host.view.convert(event.locationInWindow, from: nil))
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        throw NSError(domain: "Production context menu did not materialize", code: 1)
    }

    func testMessageContextMenuOpensThreadAsLocalTab() async throws {
        for backend in ["channel", "dm"] {
            let owner = workspace(); defer { owner.terminate() }
            TabRouter.shared.stores = { [owner] }
            let (session, model, root) = try conversation(backend)
            XCTAssertTrue(owner.popups.presentConversation(session))
            let host = try rowHost(model, root: root); defer { host.close() }
            try await host.settle()
            let menu = try contextMenu(host)
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Open as tab" })
            menu.performActionForItem(at: index); try await host.settle()
            XCTAssertEqual(model.threadRoot, root)
            XCTAssertTrue(owner.active?.activeSession === session)
            XCTAssertFalse(owner.popups.isPresented)
        }
    }

    func testDeletedChannelRootReplyEntryStillOpensAsLocalTab() async throws {
        var phase = "setup-complete"
        do {
            for serverSummary in [false, true] {
                for commandClick in [false, true] {
                    let owner = workspace(), remote = workspace()
                    defer { owner.terminate(); remote.terminate() }
                    TabRouter.shared.stores = { [remote, owner] }
                    phase = "conversation server=\(serverSummary) command=\(commandClick)"
                    let (session, model, root) = try conversation("channel")
                    if serverSummary {
                        fixture.service.serverCapabilities[model.key.server, default: []].insert("chat.thread_summary")
                    }
                    phase = "fixture-delete server=\(serverSummary) command=\(commandClick)"
                    try await fixture.base.store.queue.write { db in
                        try db.execute(sql: "UPDATE messages SET deleted_at = '2026-10-25T10:00:00Z', text = '' WHERE message_id = ?", arguments: [root])
                        if serverSummary {
                            try ChatB1.watch(db, channel: ChatPopupCaptureFixture.channel, ids: [root])
                            let metadata = ChatB1.Metadata(messageId: root, deleted: true, reactions: [],
                                threadSummary: .init(rootId: root, replyCount: 10, lastParticipants: []))
                            try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = ?",
                                arguments: [try ChatB1.encode(metadata), root])
                        }
                    }
                    phase = "wait-deleted-observation server=\(serverSummary) command=\(commandClick)"
                    for _ in 0..<100 {
                        if model.message(root)?.deleted == true { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(try XCTUnwrap(model.message(root)).deleted)
                    XCTAssertTrue(owner.popups.presentConversation(session))
                    phase = "native-row-mount server=\(serverSummary) command=\(commandClick)"
                    let host = try rowHost(model, root: root); defer { host.close() }
                    try await host.settle()
                    XCTAssertFalse(host.strings.contains("Reply in thread"))
                    let title = try XCTUnwrap(host.strings.first { $0.hasSuffix("open thread") })
                    if serverSummary { XCTAssertTrue(title.hasPrefix("10 replies")) }
                    phase = "native-row-action server=\(serverSummary) command=\(commandClick)"
                    if commandClick {
                        try withCommandClick(host) { try host.press(title) }
                    } else {
                        let menu = try contextMenu(host, title: title)
                        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Open as tab" })
                        menu.performActionForItem(at: index)
                    }
                    phase = "native-row-after-action server=\(serverSummary) command=\(commandClick)"
                    try await host.settle()
                    XCTAssertEqual(model.threadRoot, root)
                    XCTAssertTrue(owner.active?.activeSession === session)
                    XCTAssertFalse(owner.popups.isPresented)
                    XCTAssertTrue(remote.allSessions.isEmpty)
                    XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
                }
            }
        } catch {
            print("POPUP_THREAD_FAILURE phase=\(phase) type=\(String(reflecting: type(of: error))) error=\(error)")
            throw error
        }
    }

    func testTelegramTopicContextMenuOpensAsLocalTab() async throws {
        try await checkTelegramTopic(closed: false, commandClick: false)
    }

    func testClosedTelegramTopicKeepsContextMenuAndCommandClickInReadOnlyChat() async throws {
        for commandClick in [false, true] {
            try await checkTelegramTopic(closed: true, commandClick: commandClick)
        }
    }

    private func checkTelegramTopic(closed: Bool, commandClick: Bool) async throws {
        let owner = workspace(), remote = workspace(); defer { owner.terminate(); remote.terminate() }
        TabRouter.shared.stores = { [remote, owner] }
        let session = try fixture.session("telegram")
        let state = try XCTUnwrap(session.tabState), model = try XCTUnwrap(state.telegramModel)
        var snapshot = model.snapshot
        snapshot.kind = .forum; snapshot.isTopicList = true
        snapshot.capabilities.canSend = !closed
        snapshot.topics = [try XCTUnwrap(TelegramForumTopic(.init("forumTopic", ["info": .typed("forumTopicInfo", [
            "forum_topic_id": .integer(11), "name": .string("Fictional topic"), "is_closed": .bool(closed)
        ])]), chatMuted: false))]
        model.receive(snapshot)
        XCTAssertTrue(owner.popups.presentConversation(session))
        let host = ChatQuietHost(content: AnyView(TelegramConversationView(state: state, id: model.id,
            chats: fixture.telegramChats, applicationInteractive: { true }).topicList), dark: true, width: 760, height: 260)
        defer { host.close() }; try await host.settle()
        if commandClick {
            let title = try XCTUnwrap(host.strings.first { $0.hasPrefix("Fictional topic,") })
            try withCommandClick(host) { try host.press(title) }
        } else {
            let menu = try contextMenu(host)
            let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Open as tab" })
            menu.performActionForItem(at: index)
        }
        try await host.settle()
        XCTAssertEqual(owner.active?.activeSession?.toolRoute, .telegram(model.id.withTopic(.forum(11))))
        XCTAssertFalse(owner.popups.isPresented)
        XCTAssertTrue(remote.allSessions.isEmpty)
        XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
    }
}
