import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor
final class PopupPrimaryInputFocusTests: XCTestCase {
    private var host: PopupFocusIsolationTests.Host!
    private var previousContent: ((TabState) -> AnyView)!
    private var previousPill = true
    private var previousStores: (() -> [WorkspaceStore])!
    private var previousAdmit: ((@escaping () -> Void) -> Bool)?
    private var previousEnsureHost: (() -> WorkspaceStore?)!
    private var previousMenu: NSMenu?
    private var previousWindows: NSMenu?
    private var previousHelp: NSMenu?
    private var delegate: AppDelegate!
    private var chat: ChatFixture?
    private let telegram = TelegramChatsModel()

    override func setUp() async throws {
        _ = SupportTabs.shared
        previousPill = AgentPadSettingsModel.shared.showSearchPill
        AgentPadSettingsModel.shared.showSearchPill = false
        previousContent = NativeTabEngine.content
        host = try PopupFocusIsolationTests.Host(simulateKey: true)
        let router = TabRouter.shared
        previousStores = router.stores; previousAdmit = router.admit; previousEnsureHost = router.ensureHost
        router.admit = nil; router.stores = { [unowned self] in [host.store] }; router.ensureHost = { [unowned self] in host.store }
        previousMenu = NSApp.mainMenu; previousWindows = NSApp.windowsMenu; previousHelp = NSApp.helpMenu
        delegate = AppDelegate(appPersistence: AppPersistence(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-popup-windows.json")),
            agentProfiles: host.store.agentProfiles, windowControllers: [host.controller])
        delegate.installMainMenu()
        // Mount the production views, substituting only isolated data services.
        NativeTabEngine.content = { [unowned self] state in
            switch state.route {
            case .directMessage(let ref): return AnyView(ChatDMTab(state: state, ref: ref, service: chat!.service))
            case .directMessageDraft(let key, let peer): return AnyView(ChatDMPeerTab(state: state, scope: key, peer: peer, service: chat!.service))
            case .telegram(let id): return AnyView(TelegramConversationView(state: state, id: id, chats: telegram, applicationInteractive: { true }))
            case .allSessions:
                if state.allSessionsModel == nil { state.allSessionsModel = AllSessionsModel(state: state, names: .testing, profiles: host.store.agentProfiles) }
                return AnyView(AllSessionsTab(model: state.allSessionsModel!, autoload: false, owner: { [unowned self] in host.store }))
            default: return SupportTabs.shared.content(state)
            }
        }
    }

    override func tearDown() async throws {
        host.close(); host = nil
        chat?.close(); chat = nil
        NativeTabEngine.content = previousContent
        AgentPadSettingsModel.shared.showSearchPill = previousPill
        TabRouter.shared.stores = previousStores; TabRouter.shared.admit = previousAdmit; TabRouter.shared.ensureHost = previousEnsureHost
        NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows; NSApp.helpMenu = previousHelp
        delegate = nil
    }

    func testTerminalComposerAfterSearchSettingsEscape() async throws {
        let (session, editor) = try await openTerminalComposer()
        try await cycle(session)
        XCTAssertTrue(session.composerActive)
        XCTAssertTrue(editor.window === host.window)
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(host.window.firstResponder === editor, "The mounted terminal composer must reclaim focus without pane activation")
        try host.key("z", code: 6)
        XCTAssertEqual(editor.string, "z")
        XCTAssertEqual(session.composerDraft, "z", "Typing after Escape must update the production composer draft")
        XCTAssertEqual(host.terminals.map(\.input), ["", ""], "The terminal surface must not receive composer input")
    }

    func testClosedTerminalComposerUsesSurfaceAfterSearchSettingsEscape() async throws {
        let (session, editor) = try await openTerminalComposer()
        try host.key("\u{1b}", code: 53)
        try await host.settle()
        XCTAssertFalse(session.composerActive)
        XCTAssertNil(editor.window, "The closed composer must be unmounted")
        let terminal = try XCTUnwrap(session.engine.view as? PopupFocusIsolationTests.TerminalInputView)
        try await cycle(session)
        XCTAssertTrue(host.window.firstResponder === terminal)
        try host.key("z", code: 6)
        XCTAssertEqual(terminal.input, "z", "Without a composer, typing must still reach the terminal surface")
    }

    private func openTerminalComposer() async throws -> (Session, ComposerNSTextView) {
        try await host.settle()
        let session = try XCTUnwrap(host.store.active?.activeSession)
        XCTAssertTrue(session.hasProcess)
        try shortcut("l", code: 37)
        try await host.settle()
        XCTAssertTrue(session.composerActive)
        let editor = try XCTUnwrap(descendants(try XCTUnwrap(host.window.contentView)).compactMap { $0 as? ComposerNSTextView }.first)
        XCTAssertTrue(host.window.firstResponder === editor, "Command-L must mount and focus the production composer")
        XCTAssertEqual(editor.string, "")
        return (session, editor)
    }

    func testChannelComposerAfterSearchSettingsEscape() async throws { try await channel(thread: false) }
    func testChannelThreadComposerAfterSearchSettingsEscape() async throws { try await channel(thread: true) }
    func testChannelComposerBesidePinsAfterSearchSettingsEscape() async throws {
        let (session, model) = try await channelWithPins(width: 1600, expanded: false)
        XCTAssertFalse(model.pins.coversConversation(width: session.engine.view.bounds.width))
        XCTAssertEqual(descendants(session.engine.view).compactMap { $0 as? ChatMentionEditor.Editor }.count, 1)
        try await checkComposer(session, label: "Message in #general")
        XCTAssertEqual(model.threadRoot, "root", "Focus must preserve the retained thread")
    }

    func testExpandedPinnedSearchAfterSearchSettingsEscape() async throws { try await pinnedSearch(width: 1600, expanded: true) }
    func testNarrowPinnedSearchAfterSearchSettingsEscape() async throws { try await pinnedSearch(width: 900, expanded: false) }
    func testArchivedPinnedSearchAfterSearchSettingsEscape() async throws { try await pinnedSearch(width: 1600, expanded: false, archived: true) }
    func testDMComposerAfterSearchSettingsEscape() async throws { try await dm(thread: false) }
    func testDMThreadComposerAfterSearchSettingsEscape() async throws { try await dm(thread: true) }

    func testDMDraftComposerAfterSearchSettingsEscape() async throws {
        let fixture = try await makeChat()
        let session = host.store.openToolTab(.directMessageDraft(OrgKey(fixture.key), peer: "new-peer"))
        try await host.settle()
        XCTAssertTrue(session.tabState?.dmPeerModel?.writable == true)
        try await checkComposer(session, label: "Direct message")
    }

    func testTelegramChatComposerAfterSearchSettingsEscape() async throws { try await telegramConversation(topic: nil) }
    func testTelegramTopicComposerAfterSearchSettingsEscape() async throws { try await telegramConversation(topic: .forum(7)) }

    func testAllSessionsSearchAfterSearchSettingsEscape() async throws {
        let session = host.store.openToolTab(.allSessions)
        try await host.settle()
        let field = try XCTUnwrap(descendants(session.engine.view).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search names, first prompts and folders"
        })
        try await cycle(session)
        XCTAssertTrue((host.window.firstResponder as? NSTextView)?.delegate === field)
        try host.key("z", code: 6)
        XCTAssertEqual(session.tabState?.allSessionsModel?.query, "z")
    }

    func testFilesNameEditorAfterSearchSettingsEscape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("popup-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = host.store.openToolTab(.files(canonicalPath: directory.path))
        try await host.settle()
        let state = try XCTUnwrap(session.tabState)
        let edit = LocalFormTabs.shared.filesModel(state).nameEdit
        edit.beginNew(in: directory)
        try await host.settle()
        let field = try XCTUnwrap(descendants(session.engine.view).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "New file name"
        })
        try await cycle(session)
        XCTAssertTrue((host.window.firstResponder as? NSTextView)?.delegate === field)
        try host.key("z", code: 6)
        XCTAssertTrue(edit.draft?.name.contains("z") == true)
    }

    func testTabWithoutInputUsesHostingViewAfterSearchSettingsEscape() async throws {
        let session = host.store.openToolTab(.unavailable(UUID()))
        try await host.settle()
        try await cycle(session)
        XCTAssertTrue(host.window.firstResponder === session.engine.view)
    }

    func testArchivedChannelUsesHostingViewAfterSearchSettingsEscape() async throws {
        let fixture = try await makeChat(archived: true)
        let session = try openChannel(fixture)
        try await host.settle()
        XCTAssertTrue(descendants(session.engine.view).compactMap { $0 as? ChatMentionEditor.Editor }.isEmpty)
        try await cycle(session)
        XCTAssertTrue(host.window.firstResponder === session.engine.view)
    }

    private func makeChat(archived: Bool = false) async throws -> ChatFixture {
        let fixture = try ChatFixture()
        chat = fixture
        try await fixture.start(archived: archived)
        return fixture
    }

    private func openChannel(_ fixture: ChatFixture) throws -> Session {
        let ref = ChannelRef(fixture.key, channel: "channel")
        let session = host.store.openChannelTab(ref, in: try XCTUnwrap(host.store.active))
        // The real channel engine/view use a local service with cached rights.
        // Replace it before the first mount, without supplying any responder.
        session.engine.terminate()
        let engine = ChannelTabEngine(ref: ref, service: fixture.service)
        engine.conversation.tabID = session.id
        session.engine = engine
        return session
    }

    private func channel(thread: Bool) async throws {
        let fixture = try await makeChat()
        let session = try openChannel(fixture)
        try await host.settle()
        let model = try XCTUnwrap((session.engine as? ChannelTabEngine)?.conversation.model)
        if thread { model.openThread("root"); try await host.settle() }
        try await checkComposer(session, label: thread ? "Reply in thread" : "Message in #general")
        XCTAssertEqual(model.threadRoot, thread ? "root" : nil)
    }

    private func channelWithPins(width: CGFloat, expanded: Bool, archived: Bool = false) async throws -> (Session, ChatChannelModel) {
        let fixture = try await makeChat(archived: archived)
        fixture.service.serverCapabilities[fixture.key.server, default: []].insert("chat.pins")
        host.window.setContentSize(NSSize(width: width, height: 760))
        let session = try openChannel(fixture)
        try await host.settle()
        let conversation = try XCTUnwrap((session.engine as? ChannelTabEngine)?.conversation)
        let model = try XCTUnwrap(conversation.model)
        model.openThread("root")
        conversation.togglePins(); model.pins.expanded = expanded
        try await host.settle()
        XCTAssertTrue(conversation.pinsShown)
        XCTAssertEqual(model.threadRoot, "root")
        return (session, model)
    }

    private func pinnedSearch(width: CGFloat, expanded: Bool, archived: Bool = false) async throws {
        let (session, model) = try await channelWithPins(width: width, expanded: expanded, archived: archived)
        XCTAssertTrue(archived || model.pins.coversConversation(width: session.engine.view.bounds.width))
        XCTAssertTrue(descendants(session.engine.view).compactMap { $0 as? ChatMentionEditor.Editor }.isEmpty)
        let field = try XCTUnwrap(descendants(session.engine.view).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search text or author"
        })
        try await cycle(session)
        XCTAssertTrue((host.window.firstResponder as? NSTextView)?.delegate === field)
        try host.key("z", code: 6)
        XCTAssertEqual(model.pins.query, "z")
        XCTAssertEqual(model.threadRoot, "root")
        XCTAssertTrue(model.pins.isPresented)
    }

    private func dm(thread: Bool) async throws {
        let fixture = try await makeChat()
        let session = host.store.openToolTab(.directMessage(ChatDMRef(fixture.key, dm: fixture.card.dmId)))
        try await host.settle()
        let model = try XCTUnwrap(session.tabState?.dmModel)
        XCTAssertTrue(model.writable)
        if thread { model.openThread(fixture.card.messages!.first!.messageId); try await host.settle() }
        try await checkComposer(session, label: thread ? "Reply" : "Direct message")
        XCTAssertEqual(model.threadRoot, thread ? fixture.card.messages!.first!.messageId : nil)
    }

    private func telegramConversation(topic: TelegramMessageTopic?) async throws {
        let id = TelegramChatID(environment: .test, account: 42, chat: 11, topic: topic)
        var chats = TelegramChatSnapshot()
        chats.account = id.root; chats.binding = TelegramProfileBinding(environment: .test, account: 42, connectionID: UUID())
        chats.state = .complete; telegram.receive(chats)
        let session = host.store.openToolTab(.telegram(id))
        let model = TelegramConversationModel(id: id)
        var snapshot = TelegramConversationSnapshot(destination: id)
        snapshot.kind = topic == nil ? .person : .forum
        snapshot.connected = true; snapshot.capabilities.canRead = true; snapshot.capabilities.canSend = true
        model.receive(snapshot); model.provider = ConversationUIFake()
        session.tabState?.telegramModel = model
        try await host.settle()
        try await checkComposer(session, label: "Telegram message")
        XCTAssertEqual(model.draft.text, "z")
    }

    private func checkComposer(_ session: Session, label: String) async throws {
        let editor = try XCTUnwrap(descendants(session.engine.view).compactMap { $0 as? ChatMentionEditor.Editor }.first {
            $0.accessibilityLabel() == label
        }, "The real \(label) native editor must be mounted")
        XCTAssertEqual(editor.string, "")
        try await cycle(session)
        XCTAssertTrue(host.window.firstResponder === editor, "Missing search opener must restore \(label)'s native editor")
        try host.key("z", code: 6)
        XCTAssertEqual(editor.string, "z", "Typing after Escape must reach \(label)")
    }

    private func cycle(_ session: Session) async throws {
        XCTAssertNil((session.engine as? NativeTabEngine)?.rememberedFocus)
        XCTAssertNil(host.store.search.fieldFocus.field, "Search pill starts hidden")
        try shortcut("p", code: 35)
        try await host.settle()
        XCTAssertTrue(host.store.search.fieldFocused)
        XCTAssertNotNil(host.store.search.fieldFocus.field)
        try shortcut(",", code: 43)
        try await host.settle()
        XCTAssertNil(host.store.search.fieldFocus.field, "Settings unmounts the temporary search opener")
        XCTAssertTrue(try host.containsPopupFocus())
        try host.key("x", code: 7)
        XCTAssertTrue(descendants(session.engine.view).compactMap { $0 as? ChatMentionEditor.Editor }.allSatisfy { $0.string.isEmpty })
        XCTAssertEqual(host.terminals.map(\.input), ["", ""])
        try host.key("\u{1b}", code: 53)
        try await host.settle()
        XCTAssertFalse(host.store.popups.isPresented)
        XCTAssertTrue(host.store.active?.activeSession === session, "No tab switch may repair focus for us")
        XCTAssertNil((session.engine as? NativeTabEngine)?.rememberedFocus, "No remembered responder is injected or relied on")
        XCTAssertNil(host.store.search.fieldFocus.field, "Fallback must keep the pill hidden")
    }

    private func shortcut(_ character: String, code: UInt16) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "Installed Command-\(character) must dispatch")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private final class ChatFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("popup-chat-\(UUID())")
        let service: ChatService
        let card: ChatDMCard
        let key: ChatOrgKey
        private var socket: ChatSocket?

        init() throws {
            card = try JSONDecoder().decode(ChatDMCard.self, from: Self.fixture("dm_response"))
            key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"),
                accountId: "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40", orgId: "0d6f8e2a-4b1c-4a8d-9e7f-3a2b1c0d9e8f")
            service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        }

        func start(archived: Bool) async throws {
            service.closeRemoteSession = { _, _ in }
            try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "popup-test", deviceName: "Test", orgId: key.orgId), token: "test-only")
            try await service.start(mode: .server)
            let store = try XCTUnwrap(service.orgSessions[key]?.store)
            let message = try JSONDecoder().decode(ChatMessageWire.self, from: Data("""
                {"message_id":"root","channel_id":"channel","thread_root_id":null,"author_account_id":"\(key.accountId)","text":"Thread root","mentions":[],"revision":1,"seq":1,"created_at":"2026-10-08T09:00:00Z"}
                """.utf8))
            let channel = ChatChannelCard(channelId: "channel", teamId: "team", name: "general", createdBy: key.accountId,
                archived: archived, version: 1, head: 1, messages: [message])
            try store.apply(ChatSnapshot(cursors: [:], orgName: "Test", members: [
                .init(accountId: key.accountId, handle: "me", name: "Me", role: "member"),
                .init(accountId: card.peer.accountId, handle: card.peer.handle, name: card.peer.name, role: "member"),
                .init(accountId: "new-peer", handle: "new", name: "New peer", role: "member")],
                teams: [.init(teamId: "team", name: "Team", mine: true)],
                teamMembers: [.init(teamId: "team", accountId: key.accountId)], channels: [channel]), confirmsRights: "popup-test")
            service.orgSessions[key]?.snapshotOwed = false
            let routes = ChannelRoutes()
            let base = "/v1/orgs/\(key.orgId)/dms"
            routes.set(base, String(decoding: try Self.fixture("dms_response"), as: UTF8.self))
            routes.set(base + "/\(card.dmId)", String(decoding: try Self.fixture("dm_response"), as: UTF8.self))
            routes.set(base + "/\(card.dmId)/messages", String(decoding: try Self.fixture("dm_messages_response"), as: UTF8.self))
            routes.set(base + "/\(card.dmId)/threads/\(card.messages!.first!.messageId)", String(decoding: try Self.fixture("dm_thread_response"), as: UTF8.self))
            ChatStubProtocol.reset { request, _ in
                let answer = routes.answer(request.url!.path)
                return .success(.init(status: answer?.0 ?? 404, body: answer?.1 ?? Data(#"{"error":"not_found"}"#.utf8)))
            }
            service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
            let transport = FakeSocketTransport()
            let socket = ChatSocket(server: key.server, token: "test-only", makeTransport: { transport })
            self.socket = socket
            let sync = ChatSync(key: key, store: store, api: service.makeAPI(key.server), socket: socket, outbox: nil, token: "test-only")
            service.orgSessions[key]?.sync = sync
            service.serverCapabilities[key.server] = ["chat.dm"]
            sync.dm.sessionId = "popup-test"; sync.dm.configure(true)
            try await sync.dm.reloadCatalog(valid: { true })
            service.orgCurrent.refresh(service)
        }

        func close() {
            service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
            service.stopFeed(); socket?.stop()
            try? FileManager.default.removeItem(at: root)
        }

        private static func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/\(name).json"))
        }
    }
}
