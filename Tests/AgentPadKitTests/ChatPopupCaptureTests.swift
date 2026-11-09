import AgentPadQuietTestSupport
import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

/// The approved conversation study rendered through the production popup and
/// tab engines. Only the inert agent/workspace backdrop is a test fixture.
/// Export is optional; the hierarchy, containment and quiet checks always run.
@MainActor final class ChatPopupCaptureTests: XCTestCase {
    private let frames = ["channel", "dm-draft", "dm-closed", "telegram", "thread",
                          "tab", "direct-open", "narrow", "switch", "attention"]

    func testApprovedConversationFramesStayQuietAndContained() async throws {
        XCTAssertTrue(APQuietIsEnabled(), "Use scripts/test-quiet.py")
        _ = NSApplication.shared
        ChatScrollAppKitSettings.install()
        AgentPadFonts.registerOnce()
        let accessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let oldAccessibility = NSApp.accessibilityAttributeValue(accessibility)
        NSApp.accessibilitySetValue(true, forAttribute: accessibility)
        defer { NSApp.accessibilitySetValue(oldAccessibility, forAttribute: accessibility) }

        let output = ProcessInfo.processInfo.environment["AGENTPAD_CHAT_POPUP_CAPTURE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let scope = TeamServiceTestScope()
        let oldBadgeChanged = ChatNotifications.badgeChanged
        let oldApplicationActive = ChatNotifications.appActive
        ChatNotifications.badgeChanged = {}
        ChatNotifications.appActive = { false }
        defer { ChatNotifications.badgeChanged = oldBadgeChanged; ChatNotifications.appActive = oldApplicationActive }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chat-popup-capture-\(UUID())")
        ChatStubProtocol.reset { _, _ in .failure(URLError(.unsupportedURL)) }
        let fixture = try await ChatPopupCaptureFixture(root: scratch)
        defer { fixture.close(); scope.close(); ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: scratch) }

        let oldContent = NativeTabEngine.content
        NativeTabEngine.content = { state in
            switch state.route {
            case .directMessage(let ref): AnyView(ChatDMTab(state: state, ref: ref, service: fixture.service))
            case .telegram(let id): AnyView(TelegramConversationView(state: state, id: id,
                chats: fixture.telegramChats, applicationInteractive: { true }))
            default: AnyView(EmptyView())
            }
        }
        defer { NativeTabEngine.content = oldContent }
        let preferences = UserDefaults.standard
        let capturePreferences = ["chat.ux2.formatting": false, "chat.ux2.alwaysShowTime": true]
        let oldPreferences = capturePreferences.keys.map { ($0, preferences.object(forKey: $0)) }
        capturePreferences.forEach { preferences.set($0.value, forKey: $0.key) }
        defer {
            for (key, value) in oldPreferences {
                if let value { preferences.set(value, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
        }
        let settings = AgentPadSettingsModel.shared
        let oldAppearance = (settings.appearanceMode, settings.lightTerminalThemeSelection,
                             settings.darkTerminalThemeSelection, settings.pairedThemeSchemaEnabled)
        settings.prepareFirstLaunchAppearance()
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        defer {
            if !oldAppearance.3 { settings.load() }
            settings.appearanceMode = oldAppearance.0
            settings.lightTerminalThemeSelection = oldAppearance.1
            settings.darkTerminalThemeSelection = oldAppearance.2
        }

        var records: [[String: Any]] = []
        for dark in [true, false] {
            settings.appearanceMode = dark ? .dark : .light
            for frame in frames {
                let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                    engineFactory: { XCTFail("The capture must never launch an agent process"); return TestEngine() })
                let session = try fixture.session(frame)
                let width: CGFloat = frame == "narrow" ? 640 : 1236
                let height: CGFloat = frame == "narrow" ? 700 : 768
                let backdrop = ChatPopupCaptureBackdrop(store: store, frame: frame)
                    .popupHost(store.popups)
                    .frame(width: width, height: height)
                let host = ChatQuietHost(content: AnyView(backdrop), dark: dark, width: width, height: height)
                defer { host.close(); store.terminate() }
                store.popups.attach(to: host.window)
                XCTAssertTrue(store.popups.presentConversation(session))
                if frame == "attention" {
                    session.conversationPopupSource = ("Mention in #design · 10:41", "Back to Unread")
                }
                try await host.settle()
                try await host.settle()

                if frame == "dm-draft" || frame == "dm-closed" {
                    store.popups.dismiss(reason: .dismiss)
                    try await host.settle()
                    XCTAssertFalse(store.popups.isPresented)
                    XCTAssertEqual(session.tabState?.dmModel?.draft(root: nil)?.text, ChatPopupCaptureFixture.dmDraft)
                    if frame == "dm-draft" {
                        XCTAssertTrue(store.popups.presentConversation(session))
                        try await host.settle()
                        XCTAssertTrue(store.popups.showsDraftNotice)
                    }
                } else if frame == "tab" || frame == "direct-open" {
                    if frame == "direct-open" {
                        store.popups.dismiss(reason: .dismiss)
                        _ = store.popups.openConversationAsTab(session.content)
                    } else {
                        store.popups.promoteConversation()
                    }
                    try await host.settle()
                    XCTAssertFalse(store.popups.isPresented)
                    XCTAssertTrue(store.active?.activeSession === session)
                } else if frame == "switch" {
                    let dm = try fixture.session("dm-draft")
                    let telegram = try fixture.session("telegram")
                    XCTAssertTrue(store.popups.presentConversation(dm))
                    XCTAssertTrue(store.popups.presentConversation(telegram))
                    XCTAssertTrue(store.popups.presentConversation(session))
                    store.popups.showConversationPicker = true
                    try await host.settle()
                }

                let identifiers = Self.identifiers(host.nodes)
                let isPopup = !["dm-closed", "tab", "direct-open"].contains(frame)
                XCTAssertEqual(store.popups.isPresented, isPopup, frame)
                if isPopup {
                    XCTAssertTrue(identifiers.contains("popup-close"), "Missing production close control: \(frame)")
                    if frame == "switch" {
                        XCTAssertTrue(identifiers.contains("popup-conversation-picker"))
                    } else {
                        XCTAssertTrue(identifiers.contains("popup-open-as-tab"), "Missing promotion control: \(frame)")
                        XCTAssertTrue(identifiers.contains("popup-conversation-title"), "Missing conversation identity: \(frame)")
                    }
                }
                if frame == "thread" {
                    XCTAssertTrue(identifiers.contains("popup-conversation-back"))
                    XCTAssertEqual((session.engine as? ChannelTabEngine)?.conversation.model?.threadRoot,
                                   ChatPopupCaptureFixture.thread)
                }
                if ["channel", "thread", "narrow", "attention"].contains(frame) {
                    let model = try XCTUnwrap((session.engine as? ChannelTabEngine)?.conversation.model)
                    let unread = frame == "thread" ? model.threadUnreadID : model.feed.unreadID
                    XCTAssertNotNil(unread, "The fictional unread boundary must reach the real timeline: \(frame)")
                    XCTAssertTrue(host.strings.contains("New messages"), "Missing rendered unread boundary: \(frame)")
                }
                if frame == "attention" { XCTAssertTrue(identifiers.contains("popup-source-context")) }
                XCTAssertFalse(host.strings.contains { $0.contains("Offline") }, "The capture fixture must be connected: \(frame)")
                if frame == "telegram" {
                    XCTAssertEqual(session.tabState?.telegramModel?.draft.replyTo, 102)
                    XCTAssertEqual(session.tabState?.telegramRow?.kind, .group)
                    XCTAssertFalse(host.strings.contains("New messages"), "Telegram retains its provider's timeline without an unread divider")
                }
                let engineBounds = session.engine.view.convert(session.engine.view.bounds, to: host.view)
                if isPopup && frame != "switch" {
                    XCTAssertTrue(host.view.bounds.insetBy(dx: -1, dy: -1).contains(engineBounds),
                                  "Conversation escapes the \(frame) window: \(engineBounds)")
                    XCTAssertTrue(session.engine.view.window === host.window)
                }
                XCTAssertEqual(host.window.alphaValue, 0)
                XCTAssertTrue(host.window.ignoresMouseEvents)
                XCTAssertFalse(APQuietWindowHasOSFocus(host.window))
                XCTAssertNil(host.window.attachedSheet)
                XCTAssertNil(APQuietFailure())

                let id = "chat-popup-\(frame)\(dark ? "" : "-light")"
                host.view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 8_000, "The real view must render more than an empty bitmap")
                let record: [String: Any] = ["id": id, "frame": frame, "theme": dark ? "dark" : "light",
                    "pointWidth": width, "pointHeight": height, "pixelWidth": bitmap.pixelsWide,
                    "pixelHeight": bitmap.pixelsHigh, "productionForeground": true, "fixtureBackdrop": true,
                    "popup": isPopup, "quiet": APQuietIsEnabled(), "osFocus": APQuietWindowHasOSFocus(host.window),
                    "nativeMenuPixels": false, "viewBounds": NSStringFromRect(host.view.bounds),
                    "engineBounds": NSStringFromRect(engineBounds), "identifiers": identifiers.sorted(),
                    "accessibilityStrings": host.strings]
                if let output {
                    try data.write(to: output.appendingPathComponent(id + ".png"), options: .atomic)
                    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent(id + ".json"), options: .atomic)
                }
                records.append(record)
                print("CHAT_POPUP_CAPTURE \(id) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }
        XCTAssertEqual(records.count, 20)
        if let output {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        }
        XCTAssertNil(APQuietFailure())
    }

    private static func identifiers(_ nodes: [NSObject]) -> Set<String> {
        Set(nodes.compactMap { node in
            if let identifier = ChatTimelineReferenceCapture.accessibilityAttribute(node, "accessibilityIdentifier") as? String {
                return identifier
            }
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            guard node.responds(to: legacy) else { return nil }
            return node.perform(legacy, with: "AXIdentifier")?.takeUnretainedValue() as? String
        })
    }
}

@MainActor final class ChatPopupCaptureFixture {
    nonisolated static let channel = "f5000000-0000-4000-8000-000000000001"
    nonisolated static let team = "f5000000-0000-4000-8000-000000000004"
    nonisolated static let thread = "f7000000-0000-4000-8000-000000000002"
    nonisolated static let leo = "f8000000-0000-4000-8000-000000000003"
    nonisolated static let atlas = "f8000000-0000-4000-8000-000000000005"
    nonisolated static let dm = "f9000000-0000-4000-8000-000000000004"
    nonisolated static let dmDraft = "I’ll send the updated empty-state copy after the agent finishes the review."
    let base: ChatChannelExecutionTests.Fixture
    let telegramChats = TelegramChatsModel()
    let telegramID = TelegramChatID(environment: .test, account: 101, chat: -202)
    let telegramProvider = ConversationUIFake()
    private var socket: ChatSocket?
    var service: ChatService { base.service }
    private let channelCard: ChatChannelCard

    init(root: URL) async throws {
        base = try await ChatChannelExecutionTests.Fixture(root: root)
        channelCard = ChatChannelCard(channelId: Self.channel, teamId: Self.team, name: "design",
            createdBy: base.key.accountId, archived: false, version: 2)
        let transport = FakeSocketTransport()
        let me = try JSONEncoder().encode(ChatMe(accountId: base.key.accountId, sessionId: "s-anna",
            orgs: [.init(orgId: base.key.orgId, orgName: "Northstar", role: "owner", handle: "Maya", name: "Maya")],
            streams: ["account:\(base.key.accountId)": 0]))
        ChatStubProtocol.reset { request, _ in
            if request.url?.path == "/v1/me" { return .success(.init(status: 200, body: me)) }
            return .failure(URLError(.unsupportedURL))
        }
        base.service.makeSocketTransport = { transport }
        base.service.followsFeed = true
        try await base.service.start(mode: .server)
        let connectedSocket = try XCTUnwrap(base.service.socket)
        socket = connectedSocket
        // The presentation fixture publishes its entire cache below; avoid
        // starting a second, server-driven snapshot on the synthetic hello.
        base.service.orgSessions[base.key]?.sync?.stop()
        base.service.orgSessions[base.key]?.sync = nil
        base.service.orgSessions[base.key]?.outbox?.hold()
        base.service.accountFeed?.stop()
        connectedSocket.lifecycle = nil
        connectedSocket.checkServer = {}
        transport.request = nil
        connectedSocket.reconnectNow(force: true)
        try await Self.eventually { transport.request != nil }
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":3600,"version":"0.1.0"}"#)
        try await Self.eventually { connectedSocket.state == .connected }
        try base.store.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: base.key.accountId, handle: "Maya", name: "Maya", role: "owner"),
            .init(accountId: CallJSON.boris, handle: "nora", name: "Nora Chen", role: "member"),
            .init(accountId: Self.leo, handle: "leo", name: "Leo Park", role: "member")],
            teams: [.init(teamId: Self.team, name: "Product", mine: true)],
            teamMembers: [.init(teamId: Self.team, accountId: base.key.accountId),
                          .init(teamId: Self.team, accountId: CallJSON.boris),
                          .init(teamId: Self.team, accountId: Self.leo)],
            channels: [channelCard], channelsComplete: true), confirmsRights: "s-anna")
        try base.store.endChannelsRead(since: 0, seen: [Self.channel])
        let channelMessages: [(Int, String, String, String?, String?)] = [
            (1, base.key.accountId, "The workspace picker is ready for a copy pass. Keeping the first step short.", nil, nil),
            (2, CallJSON.boris, "@Maya Can we keep “Start a workspace” as the primary action?", nil, nil),
            (3, Self.leo, "Yes. One clear action, then the recent folders below it.", nil, nil),
            (4, Self.leo, "The empty-state review is ready. All keyboard targets have visible focus.", nil, "Atlas"),
            (5, Self.leo, "Yes. It describes what happens next without mentioning a folder.", Self.thread, nil),
            (6, CallJSON.boris, "That works. The helper text can explain that you can use an existing project.", Self.thread, nil),
            (7, Self.leo, "Agreed. I’ll include both sizes in the review.", Self.thread, nil)]
        let wires = try channelMessages.map { number, author, text, thread, agent -> ChatMessageWire in
            var value: [String: Any] = ["message_id": String(format: "f7000000-0000-4000-8000-%012d", number),
                "channel_id": Self.channel, "author_account_id": author, "text": text,
                "revision": 1, "seq": number, "created_at": "2026-10-24T08:\([36, 41, 42, 44, 42, 43, 44][number - 1]):00Z"]
            if let thread { value["thread_root_id"] = thread }
            if let agent { value["author_agent_id"] = Self.atlas; value["author_agent_name"] = agent }
            if number == 2 { value["mentions"] = [["account_id": base.key.accountId]] }
            return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: value))
        }
        try await base.store.queue.write { db in
            for message in wires { _ = try ChatMessages.write(db, message) }
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 1, thread_read_seq = 1 WHERE channel_id = ?", arguments: [Self.channel])
            _ = try ChatUnread.markRead(db, channel: Self.channel, upTo: 5, thread: Self.thread)
            try ChatMessages.applyThread(db, channel: Self.channel, root: Self.thread,
                epoch: ChatMessages.epoch(db, Self.channel),
                page: ChatMessagesPage(messages: wires.filter { $0.threadRootId != nil }, next: nil, head: 7))
        }

        let texts = ["Do you have the latest copy for the empty workspace?",
                     "The agent is reviewing it now. I’ll send the wording when it’s ready.",
                     "Perfect. A short version for the narrow layout would help too."]
        let dmMessages = texts.enumerated().map { index, text in
            ChatDMMessageWire(messageId: "popup-dm-\(index)", dmId: Self.dm, threadRootId: nil,
                authorAccountId: index == 1 ? base.key.accountId : CallJSON.boris, text: text, mentions: [],
                revision: 1, seq: index + 1, createdAt: "2026-10-24T08:\([28, 29, 31][index]):00Z", editedAt: nil, deletedAt: nil)
        }
        let dmCard = ChatDMCard(dmId: Self.dm,
            peer: .init(accountId: CallJSON.boris, name: "Nora Chen", handle: "nora", active: true),
            state: "active", closedAt: nil, version: 1, createdAt: "2026-10-24T08:28:00Z",
            head: 3, messages: dmMessages, messagesBefore: nil)
        let catalog = try JSONEncoder().encode(ChatDMPage(dms: [dmCard], next: nil))
        let card = try JSONEncoder().encode(dmCard)
        let page = try JSONEncoder().encode(ChatDMMessagesPage(messages: dmMessages, next: nil, head: 3))
        let threadPage = try JSONEncoder().encode(ChatMessagesPage(messages: wires.filter { $0.threadRootId != nil }, next: nil, head: 7))
        ChatStubProtocol.reset { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/dms") { return .success(.init(status: 200, body: catalog)) }
            if path.hasSuffix("/dms/\(Self.dm)") { return .success(.init(status: 200, body: card)) }
            if path.contains("/dms/") { return .success(.init(status: 200, body: page)) }
            if path.contains("/threads/") { return .success(.init(status: 200, body: threadPage)) }
            return .failure(URLError(.unsupportedURL))
        }
        let sync = ChatSync(key: base.key, store: base.store,
            api: ChatAPI(server: base.key.server, protocolClasses: [ChatStubProtocol.self]), socket: connectedSocket,
            outbox: nil, token: "fixture-only")
        base.service.orgSessions[base.key]?.sync = sync
        base.service.orgSessions[base.key]?.snapshotOwed = false
        base.service.serverCapabilities[base.key.server] = ["chat.dm"]
        sync.dm.sessionId = "s-anna"
        sync.dm.configure(true)
        try await sync.dm.reloadCatalog(valid: { true })
        base.service.orgCurrent.refresh(base.service)
        if let current = base.service.orgCurrent.model {
            current.set(try await base.store.queue.read { try ChatOrgView.read($0) })
        }
        var chats = TelegramChatSnapshot()
        chats.binding = .init(environment: .test, account: telegramID.account, connectionID: UUID())
        chats.account = TelegramChatID(environment: .test, account: telegramID.account, chat: 0)
        chats.state = .complete
        chats.mainRows = [telegramRow]
        chats.suggestionRows = [telegramRow]
        telegramChats.attach(ChatPopupCaptureTelegramCatalog(snapshot: chats, row: telegramRow))
        try await Self.eventually { self.telegramChats.connected }
    }

    func session(_ frame: String) throws -> Session {
        let id = UUID()
        if frame.hasPrefix("dm-") {
            let state = TabState(route: .directMessage(ChatDMRef(base.key, dm: Self.dm)))
            let model = ChatDMModel(key: base.key, dm: Self.dm, state: state, service: service)
            state.dmModel = model
            XCTAssertNotNil(model.card)
            XCTAssertNotNil(model.saveDraft(Self.dmDraft, root: nil))
            let session = Session(id: id, engine: NativeTabEngine(state: state, tabID: id),
                currentDirectory: URL(fileURLWithPath: "/fictional/northstar"), agent: .terminal)
            session.content = .tool(state.route)
            return session
        }
        if frame == "telegram" {
            let state = TabState(route: .telegram(telegramID)), model = TelegramConversationModel(id: telegramID)
            var value = TelegramConversationSnapshot(destination: telegramID)
            value.title = "Launch crew"; value.kind = .group; value.revision = 1
            value.connected = true; value.hasOlder = false
            value.capabilities.canRead = true; value.capabilities.canSend = true; value.capabilities.sender = "Maya"
            value.draft.replyTo = 102
            value.messages = try [
                (Int64(101), "Leo Park", "The launch checklist is ready for a final look.", false),
                (Int64(102), "Nora Chen", "Can you confirm the workspace copy before lunch?", false),
                (Int64(103), "Maya", "The review is nearly done. I’ll share the final wording here.", true)
            ].map { message, author, text, outgoing in
                let raw = TDLibMessage("message", ["id": .integer(message), "chat_id": .integer(-202),
                    "date": .integer([1_792_831_080, 1_792_831_380, 1_792_831_440][Int(message - 101)]),
                    "is_outgoing": .bool(outgoing), "can_be_saved": .bool(true),
                    "sender_id": .typed("messageSenderUser", ["user_id": .integer(message)]),
                    "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string(text), "entities": .array([])])])])
                var decoded = try XCTUnwrap(TelegramMessageDecoder.decode(raw, now: Date(), author: author))
                if message == 101 {
                    decoded.attachment = TelegramFile(id: 901, name: "launch-checklist.pdf", size: 131_072, mime: "application/pdf")
                    decoded.attachment?.complete = true
                    decoded.attachment?.downloaded = 131_072
                }
                return decoded
            }
            model.receive(value); model.provider = telegramProvider
            model.showMessage(102)
            state.telegramModel = model
            state.telegramRow = telegramRow
            let session = Session(id: id, engine: NativeTabEngine(state: state, tabID: id),
                currentDirectory: URL(fileURLWithPath: "/fictional/northstar"), agent: .terminal)
            session.content = .tool(state.route)
            return session
        }
        let ref = ChannelRef(base.key, channel: Self.channel), engine = ChannelTabEngine(ref: ChannelRef(base.key, channel: Self.channel), service: service)
        engine.conversation.tabID = id
        engine.conversation.update(.ready(channelCard, team: "Northstar / Product", offline: false),
            key: base.key, store: base.store, service: service)
        let model = try XCTUnwrap(engine.conversation.model)
        model.beginReading(root: nil)
        model.saveDraft(frame == "tab" ? "Thanks — I’ll add the final copy to the review." :
            frame == "switch" ? "I agree. Let’s use “Start a workspace”." : "", root: nil)
        if frame == "thread" { model.openThread(Self.thread); model.beginReading(root: Self.thread) }
        if frame == "attention" { model.navigate(to: try XCTUnwrap(model.message(Self.thread))) }
        let session = Session(id: id, engine: engine, currentDirectory: URL(fileURLWithPath: "/fictional/northstar"), agent: .terminal)
        session.content = .channel(ref)
        return session
    }

    func close() {
        base.service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
        base.service.stopFeed()
        socket?.stop()
    }

    private var telegramRow: TelegramChatRow {
        .init(id: telegramID, title: "Launch crew", username: "", kind: .group,
              unreadCount: 1, unreadMentionCount: 0, inMain: true, inArchive: false,
              pinned: false, hidden: false, lastMessageDate: 1_792_831_440, knownRelevant: true)
    }

    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The isolated presentation fixture did not become ready")
    }
}

/// A finite metadata publication, with no Telegram client, login, or file IO.
private actor ChatPopupCaptureTelegramCatalog: TelegramChatProvider {
    let snapshot: TelegramChatSnapshot
    let row: TelegramChatRow
    init(snapshot: TelegramChatSnapshot, row: TelegramChatRow) { self.snapshot = snapshot; self.row = row }
    func chatSnapshots() -> AsyncStream<TelegramChatSnapshot> {
        AsyncStream { $0.yield(snapshot); $0.finish() }
    }
    func setChatMode(_ id: TelegramChatID, mode: TelegramChatMode) {}
    func searchTelegram(_ query: String) -> AsyncStream<TelegramSearchSnapshot> {
        AsyncStream { $0.yield(.init(query: query, hits: [.init(row: row)])); $0.finish() }
    }
    func resolveChat(_ hit: TelegramSearchHit) -> TelegramChatRow? { hit.row }
    func didOpenChat(_ id: TelegramChatID) {}
    func chat(_ id: TelegramChatID) -> TelegramChatRow? { id == row.id ? row : nil }
    func setChatScanPaused(_ reason: String?) {}
}

/// No owner terminal, account, workspace or process is consulted. This inert
/// backdrop makes the real popup scrim and containment visible in the study.
private struct ChatPopupCaptureBackdrop: View {
    @Bindable var store: WorkspaceStore
    let frame: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, Color.orange, Color.green], id: \.self) { $0.opacity(0.7).frame(width: 9, height: 9).clipShape(Circle()) }
                Text("AgentPad").font(Theme.display(11)).foregroundStyle(.secondary)
                Spacer()
                Label("Search or jump to…", systemImage: "magnifyingglass")
                    .font(Theme.display(11)).foregroundStyle(.secondary).frame(width: 310, alignment: .leading)
                    .padding(6).background(Theme.chromeForeground.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }.padding(.horizontal, 14).frame(height: 42)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 21) {
                    Text("Northstar").font(Theme.display(14, weight: .semibold))
                    Text("Maya · online").font(Theme.display(10)).foregroundStyle(.secondary)
                    Label("Notifications", systemImage: "bell")
                    Label("Unread", systemImage: "tray")
                    Text("My agents").font(Theme.display(10)).foregroundStyle(.secondary)
                    Label("Claude · empty states", systemImage: "terminal").padding(8)
                        .background(Theme.chromeForeground.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    Label("Reviewer", systemImage: "checkmark.bubble")
                    Text("Product").font(Theme.display(10)).foregroundStyle(.secondary)
                    Label("design", systemImage: "number")
                    Label("releases", systemImage: "number")
                    Text("Direct messages").font(Theme.display(10)).foregroundStyle(.secondary)
                    Label("Nora Chen", systemImage: "person.crop.circle")
                    Label("Leo Park", systemImage: "person.crop.circle")
                    Text("Telegram · Work").font(Theme.display(10)).foregroundStyle(.secondary)
                    Label("Launch crew", systemImage: "paperplane")
                    Spacer(minLength: 0)
                    Label("Settings", systemImage: "gearshape")
                }.font(Theme.display(12)).padding(18).frame(width: 224, alignment: .leading)
                    .background(Theme.chromeForeground.opacity(0.02))
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text("●  Claude · empty states").font(Theme.display(11)).padding(12)
                        if ["tab", "direct-open"].contains(frame), store.active?.activeSession != nil {
                            Text("# design").font(Theme.display(11, weight: .semibold)).padding(12)
                                .background(ChatAppearance.surface)
                        }
                        Spacer()
                    }.frame(height: 36).background(Theme.chromeForeground.opacity(0.025))
                    Divider()
                    if ["tab", "direct-open"].contains(frame), !store.popups.isPresented,
                       let session = store.active?.activeSession {
                        ChatPopupCaptureEngine(session: session)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("~/northstar   ·   ui/empty-states").foregroundStyle(.secondary)
                            Text("Claude Code").font(.system(size: 25, weight: .bold, design: .monospaced))
                            Text("Sonnet · Northstar workspace").foregroundStyle(.secondary)
                            Text("❯ Review the empty states for the new workspace flow.")
                            Text("I’ll check the copy and keyboard navigation,\nthen compare the small-window layouts.")
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.chromeForeground.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                            Text("✓ Read src/workspace/EmptyState.tsx\n✓ Read src/workspace/WorkspacePicker.tsx").foregroundStyle(.secondary)
                            Text("I found two labels that can be clearer.\nThe layout already adapts to a narrow window.")
                            Spacer(minLength: 0)
                            Text("❯ Ask a follow-up…").foregroundStyle(.secondary).padding(15)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.chromeHairline))
                        }.font(.system(size: 13, design: .monospaced)).padding(32)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            Divider()
            HStack { Text("●  Connected    ui/empty-states"); Spacer(); Text("1 workspace · 1 agent") }
                .font(Theme.display(9)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24)
        }.foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
    }
}

private struct ChatPopupCaptureEngine: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> NSView { session.engine.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
