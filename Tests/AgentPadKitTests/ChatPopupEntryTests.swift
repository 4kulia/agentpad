import AppKit
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

@MainActor final class ChatPopupEntryTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }
    private func root() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("chat-popup-entry-\(UUID())")
        roots.append(value); return value
    }
    private func store() -> WorkspaceStore {
        let root = root()
        return WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            agentProfiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")),
            engineFactory: { XCTFail("Opening a chat must not start an agent"); return TestEngine() })
    }
    private func search() -> EverywhereSearchModel {
        let root = root()
        return EverywhereSearchModel(messages: .init(context: { nil }, availability: { .noTeam }, fetch: { _, _ in
            XCTFail("No live search in fixtures"); return .init(hits: [], next: nil)
        }), indexing: .init(index: ConversationIndex(directory: root, roots: [:], visibility: { .init(channelIds: []) })),
            catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")),
            profiles: AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            telegram: TelegramSearchModel(chats: TelegramChatsModel()), visibility: { .init(channelIds: []) })
    }
    private func row(_ id: Int64 = 7) -> TelegramChatRow {
        .init(id: .init(environment: .test, account: 42, chat: id), title: "Fixture conversation", username: "", kind: .person,
              unreadCount: 3, unreadMentionCount: 0, inMain: true, inArchive: false, pinned: false, hidden: false,
              lastMessageDate: 100, knownRelevant: true)
    }
    func testSearchCommandReturnUsesTabIntentForSelectedConversationIncludingExistingTabResult() async throws {
        let model = search()
        let channel = PaletteItem(id: "channel", title: "Fixture channel", subtitle: "Channel",
            kind: .channel(.init(server: "https://chat.example.com", account: "account", org: "org", channel: "channel")), symbol: "number", iconAsset: nil)
        let existing = PaletteItem(id: "existing", title: "Fixture DM", subtitle: "Open tab",
            kind: .tab(sessionId: UUID(), workspaceId: UUID(), windowId: UUID()), symbol: "person", iconAsset: nil)
        let agent = PaletteItem(id: "agent", title: "Fixture terminal", subtitle: "Agent",
            kind: .agent(templateId: "terminal"), symbol: "terminal", iconAsset: nil)
        model.quickItems = { [channel, existing, agent] }
        model.isConversationQuick = { $0.id == channel.id || $0.id == existing.id }
        var actions: [String] = []
        model.activateQuick = { actions.append("popup:" + $0.id) }
        model.activateQuickAsTab = { actions.append("tab:" + $0.id) }
        model.openResults = { actions.append("results") }
        model.begin()
        for _ in 0..<100 { if model.quick.count == 3 { break }; await Task.yield() }
        XCTAssertEqual(Set(model.quick.map(\.id)), [channel.id, existing.id, agent.id])
        model.selected = "q:channel"; model.commandReturn()
        model.selected = "q:existing"; model.commandReturn()
        model.activate("q:existing")
        model.selected = "q:agent"; model.commandReturn()
        model.selected = nil; model.commandReturn()
        XCTAssertEqual(actions, ["tab:channel", "tab:existing", "popup:existing", "results", "results"])
    }
    func testSearchMessageExplicitTabActionIsIndependentOfLaterInputEvents() {
        let model = search()
        let hit = ChatSearchHit(kind: .dm, targetID: "dm", messageID: "message", threadRootID: "root", messageSeq: 9,
            revision: 1, authorAccountID: "peer", createdAt: "2026-10-24T09:00:00Z", snippet: "Fixture message")
        var ordinary: [ChatSearchHit] = [], tabs: [ChatSearchHit] = []
        model.openMessage = { ordinary.append($0) }; model.openMessageAsTab = { tabs.append($0) }
        model.navigateMessage(hit, asTab: true); model.navigateMessage(hit)
        XCTAssertEqual(tabs, [hit]); XCTAssertEqual(ordinary, [hit])
    }
    func testTelegramPlainClickNeverFocusesLocalOrRemoteTabAndExplicitTabStaysLocal() throws {
        let origin = store(), remote = store(), router = TabRouter(), row = row()
        defer { origin.terminate(); remote.terminate() }
        router.stores = { [origin, remote] }
        var raised: [UUID] = []; router.revealWindow = { raised.append($0.windowID) }
        let remoteTab = try XCTUnwrap(TelegramTabs.open(row, from: remote, router: router, asTab: true))
        let localTab = try XCTUnwrap(TelegramTabs.open(row, from: origin, router: router, asTab: true))
        XCTAssertFalse(localTab === remoteTab)
        let localActive = origin.active?.activeSession?.id
        let popup = try XCTUnwrap(TelegramTabs.open(row, from: origin, router: router))
        XCTAssertTrue(popup.isConversationPopup)
        XCTAssertTrue(origin.popups.visibleConversation === popup)
        XCTAssertEqual(origin.active?.activeSession?.id, localActive)
        XCTAssertTrue(router.owner(of: try XCTUnwrap(popup.tabState))?.store === origin)
        XCTAssertEqual(origin.allSessions.map(\.id), [localTab.id])
        XCTAssertTrue(TelegramTabs.open(row, from: origin, router: router, asTab: true) === localTab)
        XCTAssertTrue(raised.isEmpty, "Conversation routing never raises another window or Space")
    }
    func testTelegramTopicsReplaceOnePopupAndBackUsesItsInitiatingWindow() throws {
        let origin = store(), remote = store(), router = TabRouter(), row = row()
        defer { origin.terminate(); remote.terminate() }
        router.stores = { [remote, origin] }
        let parent = try XCTUnwrap(TelegramTabs.open(row, from: origin, router: router))
        let topic = try XCTUnwrap(TelegramTabs.openTopic(row.id.withTopic(.forum(11)), title: "Fixture topic",
            state: try XCTUnwrap(parent.tabState), router: router))
        XCTAssertEqual(topic.tabState?.telegramTopicTitle, "Fixture topic")
        XCTAssertEqual(topic.tabState?.telegramRow, row)
        XCTAssertTrue(topic.isConversationPopup); XCTAssertTrue(origin.popups.backStack.isEmpty)
        XCTAssertTrue(remote.allSessions.isEmpty); XCTAssertTrue(remote.popups.sessions.isEmpty)
        let back = try XCTUnwrap(TelegramTabs.openTopic(row.id, title: nil, state: try XCTUnwrap(topic.tabState), router: router))
        XCTAssertTrue(back === parent); XCTAssertNil(back.tabState?.telegramTopicTitle)
        XCTAssertTrue(origin.allSessions.isEmpty)
    }
    func testTelegramFailedSaveBlocksDismissSwitchAndPromotionUntilRetry() async throws {
        for action in ["dismiss", "switch", "promote"] {
            let origin = store(), router = TabRouter(), row = row(), provider = ConversationUIFake()
            defer { origin.terminate() }
            router.stores = { [origin] }
            let popup = try XCTUnwrap(TelegramTabs.open(row, from: origin, router: router))
            let model = TelegramConversationModel(id: row.id)
            popup.tabState?.telegramModel = model; model.provider = provider
            await provider.setDraftWritesSucceed(false)
            model.change {
                $0.text = "Fictional \(action) draft"; $0.replyTo = 19
                $0.attachments = [.init(id: UUID(), name: "fixture.txt", mime: "text/plain", size: 20)]
            }
            let expected = model.draft
            switch action {
            case "dismiss": origin.popups.dismiss(reason: .dismiss)
            case "switch": _ = TelegramTabs.open(self.row(8), from: origin, router: router)
            default: _ = TelegramTabs.open(row, from: origin, router: router, asTab: true)
            }
            for _ in 0..<100 { if !origin.popups.conversationSaving, origin.popups.conversationSaveError != nil { break }; await Task.yield() }
            XCTAssertTrue(origin.popups.visibleConversation === popup, action)
            XCTAssertNotNil(origin.popups.conversationSaveError, action)
            XCTAssertEqual(model.draft, expected, action); XCTAssertTrue(model.hasUnsavedDraft, action)
            XCTAssertTrue(origin.allSessions.isEmpty, action)
            await provider.setDraftWritesSucceed(true)
            origin.popups.retryConversationSave()
            for _ in 0..<100 { if !origin.popups.conversationSaving { break }; await Task.yield() }
            XCTAssertNil(origin.popups.conversationSaveError, action)
            XCTAssertEqual(model.draft, expected, action); XCTAssertFalse(model.hasUnsavedDraft, action)
            switch action {
            case "switch": XCTAssertEqual(origin.popups.visibleConversation?.toolRoute, .telegram(self.row(8).id))
            case "promote": XCTAssertNil(origin.popups.visibleConversation); XCTAssertTrue(origin.allSessions.contains { $0 === popup })
            default: XCTAssertNil(origin.popups.visibleConversation)
            }
        }
    }
    func testNotificationArrivalIsPassiveAndQueuedExplicitTabIntentSurvivesStartup() {
        let ledger = AttentionLedger(), navigation = NotificationNavigation(ledger: AttentionLedger())
        let event = AttentionEvent(source: "fixture", object: "message", kind: .mention,
            destination: .message(channel: "channel", message: "message", thread: nil, sequence: 9))
        let route = NotificationNavigation(ledger: ledger)
        var actions: [String] = []
        route.validate = { _ in true }; route.open = { _ in actions.append("popup"); return true }
        route.openAsTab = { _ in actions.append("tab"); return true }
        ledger.upsert(event); XCTAssertTrue(actions.isEmpty)
        route.activate(event.id, asTab: true); XCTAssertTrue(actions.isEmpty)
        route.finishStartup(); route.activate(event.id)
        XCTAssertEqual(actions, ["tab", "popup"])
        navigation.telegramReady = { true }
        navigation.telegramActivate = { _ in actions.append("telegram popup"); return true }
        navigation.telegramActivateAsTab = { _ in actions.append("telegram tab"); return true }
        navigation.activate("telegram:fixture", asTab: true); navigation.finishStartup()
        XCTAssertEqual(actions, ["tab", "popup", "telegram tab"])
    }
}

@MainActor final class TelegramPopupDraftTests: XCTestCase {
    private let id = TelegramChatID(environment: .test, account: 42, chat: 7)
    func testFailedFlushRetainsWholeDraftAndRetryPersistsAttachmentsAndReply() async throws {
        let model = TelegramConversationModel(id: id), provider = ConversationUIFake()
        model.provider = provider; await provider.setDraftWritesSucceed(false)
        model.change {
            $0.text = "Fictional reply"
            $0.replyTo = 19
            $0.attachments = [.init(id: UUID(), name: "fixture.txt", mime: "text/plain", size: 20)]
        }
        let expected = model.draft
        XCTAssertTrue(model.hasUnsavedDraft)
        do { try await model.flushDraft(); XCTFail("A failed save must prevent dismissal") }
        catch { XCTAssertEqual(error.localizedDescription, "Draft not saved. Keep this conversation open and retry.") }
        XCTAssertEqual(model.draft, expected); XCTAssertTrue(model.hasUnsavedDraft); XCTAssertTrue(model.draftSaveFailed)
        await provider.setDraftWritesSucceed(true)
        try await model.flushDraft()
        XCTAssertEqual(model.draft, expected); XCTAssertFalse(model.hasUnsavedDraft); XCTAssertFalse(model.draftSaveFailed); XCTAssertNil(model.problem)
        let writes = await provider.writes
        XCTAssertFalse(writes.isEmpty); XCTAssertTrue(writes.allSatisfy { $0 == expected })
    }
    func testCleanDraftNeedsNoProviderAndTargetOverridesRetainedAnchor() async throws {
        let model = TelegramConversationModel(id: id), provider = ConversationUIFake()
        try await model.flushDraft(); XCTAssertFalse(model.hasUnsavedDraft)
        var snapshot = TelegramConversationSnapshot(destination: id)
        snapshot.capabilities.canRead = true
        model.receive(snapshot); model.provider = provider; model.scrollAnchor = "retained-row"
        model.showMessage(101)
        for _ in 0..<100 { if !(await provider.requestedMessages).isEmpty { break }; await Task.yield() }
        let requests = await provider.requestedMessages
        XCTAssertEqual(requests, [101]); XCTAssertEqual(model.requestedMessage, 101)
        let message = TelegramMessage(id: "target-row", messageID: 101, senderID: 8, author: "Fixture peer", date: .distantPast,
            edited: false, outgoing: false, text: "Fictional target", entities: [], content: .message, delivery: .received,
            replyTo: nil, replyPreview: nil, protectedContent: false, unreadMention: false, expiresAt: nil, attachment: nil)
        snapshot.messages = [message]; snapshot.revision += 1; model.receive(snapshot)
        XCTAssertEqual(model.scrollAnchor, "target-row"); XCTAssertEqual(model.requestedMessage, 101)
        XCTAssertEqual(model.presentation.rows.map(\.id), ["target-row"], "Telegram never adds an unread divider")
    }

    func testTelegramTargetSurvivesRecentPageUntilRequestedMessageArrives() async throws {
        try await checkTelegramPagedTarget()
    }

    func testTelegramTargetSurvivesTemporaryAccessLossAndRestoration() async throws {
        try await checkTelegramPagedTarget(revalidateBeforeFirstPage: true)
    }

    func testTelegramTargetSurvivesHistoryFailureAndExistingRetry() async throws {
        try await checkTelegramPagedTarget(historyFailure: true)
    }

    private func checkTelegramPagedTarget(revalidateBeforeFirstPage: Bool = false, historyFailure: Bool = false) async throws {
        let model = TelegramConversationModel(id: id), provider = ConversationUIFake()
        var snapshot = TelegramConversationSnapshot(destination: id)
        snapshot.capabilities.canRead = true; snapshot.hasOlder = true
        model.receive(snapshot); model.provider = provider
        model.showMessage(5)
        for _ in 0..<100 { if !(await provider.requestedMessages).isEmpty { break }; await Task.yield() }
        if revalidateBeforeFirstPage {
            snapshot.capabilities.canRead = false; snapshot.revision += 1; model.receive(snapshot)
            XCTAssertEqual(model.requestedMessage, 5); XCTAssertNil(model.scrollAnchor)
            XCTAssertTrue(model.presentation.rows.isEmpty)
            snapshot.capabilities.canRead = true; snapshot.revision += 1; model.receive(snapshot)
            XCTAssertEqual(model.requestedMessage, 5); XCTAssertNil(model.scrollAnchor)
        }
        func message(_ sequence: Int64) -> TelegramMessage {
            TelegramMessage(id: "reply-\(sequence)", messageID: sequence, senderID: 8, author: "Fixture peer", date: .distantPast,
                edited: false, outgoing: false, text: "Fictional reply \(sequence)", entities: [], content: .message, delivery: .received,
                replyTo: nil, replyPreview: nil, protectedContent: false, unreadMention: false, expiresAt: nil, attachment: nil)
        }
        snapshot.messages = (81...130).map { message(Int64($0)) }
        snapshot.revision += 1; model.receive(snapshot)
        for _ in 0..<100 { if !(await provider.requestedMessages).isEmpty { break }; await Task.yield() }
        let requests = await provider.requestedMessages
        XCTAssertEqual(requests, [5])
        XCTAssertEqual(model.requestedMessage, 5); XCTAssertNil(model.scrollAnchor)
        XCTAssertEqual(model.presentation.rows.map(\.id), (81...130).map { "reply-\($0)" })
        let observations = await provider.observations
        XCTAssertTrue(observations.isEmpty, "Loading a page does not submit a read observation")
        if historyFailure {
            snapshot.error = "Earlier messages could not be loaded. Try again."
            snapshot.revision += 1; model.receive(snapshot)
            XCTAssertEqual(model.snapshot.error, snapshot.error)
            XCTAssertEqual(model.requestedMessage, 5); XCTAssertNil(model.scrollAnchor)
            let beforeRetry = await provider.historyRequests
            XCTAssertTrue(beforeRetry.isEmpty, "No automatic retry loop")
            // The existing Telegram error banner's Retry history action.
            model.load(latest: true)
            for _ in 0..<100 { if !(await provider.historyRequests).isEmpty { break }; await Task.yield() }
            let retries = await provider.historyRequests
            XCTAssertEqual(retries, [true])
            let afterFailure = await provider.observations
            XCTAssertTrue(afterFailure.isEmpty)
            snapshot.error = nil
        }
        snapshot.messages.insert(message(5), at: 0)
        snapshot.revision += 1; model.receive(snapshot)
        XCTAssertEqual(model.requestedMessage, 5); XCTAssertEqual(model.scrollAnchor, "reply-5")
        XCTAssertEqual(model.presentation.rows.map(\.id), ["reply-5"] + (81...130).map { "reply-\($0)" })
        let finalObservations = await provider.observations
        XCTAssertTrue(finalObservations.isEmpty, "Resolving a target alone never acknowledges messages")
    }
}
