import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor final class CompositionTabsTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-" + UUID().uuidString)
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private var hosts: [WorkspaceStore] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let teamID = "f5000000-0000-4000-8000-000000000004"
    override func tearDown() async throws {
        hosts.forEach { $0.terminate() }; hosts = []
        for f in fixtures { f.sender?.hold(); await f.service.disconnect() }
        fixtures = []; ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture() async throws -> (ChatChannelExecutionTests.Fixture, ChatOrgModel) {
        ChatNotifications.badgeChanged = {}
        let f = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent(UUID().uuidString)); fixtures.append(f)
        f.service.isServerKnown = { _, _ in true }
        f.service.serverCapabilities[f.key.server] = ["chat.channel_ux1", "chat.session_tools"]
        f.calls.deliversAsks = true
        try write(f.store.queue) { try ChatCallStore.replaceCatalog($0, [CallJSON.card(owner: CallJSON.boris, teams: [teamID])]) }
        try f.write("UPDATE agent_channels SET owner_account_id = ?", [CallJSON.boris])
        let model = try XCTUnwrap(ChatOrgModel.current(f.service)); model.showsOffline = { false }
        try await wait { model.agentsVisible && model.visibleChannel(self.channel) != nil }
        return (f, model)
    }
    private func host(drafts: DraftRepository? = nil) -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, drafts: drafts,
            engineFactory: { XCTFail("Composition tab started a terminal"); return TestEngine() }, peerStores: { [weak self] in self?.hosts ?? [] })
        hosts.append(store); return store
    }
    private func tabs(_ f: ChatChannelExecutionTests.Fixture, _ org: ChatOrgModel) -> CompositionTabs {
        let router = TabRouter(); router.stores = { [weak self] in self?.hosts ?? [] }
        return CompositionTabs(router: router, chat: f.service, team: f.teamService, orgModel: { org })
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition())
    }
    private func write(_ queue: DatabaseQueue, _ body: (Database) throws -> Void) throws { try queue.write(body) }

    func testPersonalAskIsSeparateFromChannelDraftAndSurvivesPopupCloseAndRestartWithOneRequest() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), first = host(), second = host()
        let route = ToolRoute.ask(OrgKey(f.key), agentID: CallJSON.agent)
        let session = try XCTUnwrap(tabs.open(route, from: first)), state = try XCTUnwrap(session.tabState), form = tabs.askModel(state)
        form.prompt = "Unfinished personal question\n\nwith Markdown"
        let channelModel = ChatChannelModel(key: f.key, channel: channel); channelModel.service = f.service; channelModel.follow(f.store)
        channelModel.saveDraft("Channel draft stays separate", root: nil)
        let otherPopup = try XCTUnwrap(tabs.open(route, from: second))
        XCTAssertFalse(otherPopup === session)
        XCTAssertFalse(second.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(second.active)))
        XCTAssertTrue(tabs.askModel(state) === form)
        XCTAssertEqual(form.prompt, "Unfinished personal question\n\nwith Markdown")
        let location = try XCTUnwrap(tabs.router.owner(of: session.id))
        XCTAssertTrue(location.store === first)
        XCTAssertTrue(first.tabCloseCoordinator.prepare([session]))
        first.popups.dismiss(reason: .dismiss)
        let reopened = try XCTUnwrap(tabs.open(route, from: first)), restored = tabs.askModel(try XCTUnwrap(reopened.tabState))
        XCTAssertEqual(restored.prompt, form.prompt)
        XCTAssertEqual(channelModel.draft(root: nil), "Channel draft stays separate")
        XCTAssertTrue(restored.canSend)
        restored.send(); restored.send()
        XCTAssertNil(restored.problem)
        let requests = try f.store.outbox.commands().filter { $0.type == "request.create" }
        XCTAssertEqual(requests.count, 1)
        let args = ChatService.args(try XCTUnwrap(requests.first))
        XCTAssertNil(args["channel_id"]); XCTAssertEqual(args["thread_id"], .null); XCTAssertEqual(args["origin"], .null)
        let restartedState = TabState(route: route), restarted = tabs.askModel(restartedState)
        restarted.send()
        XCTAssertEqual(restarted.history.count, 1)
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "request.create" }.count, 1)
        let disk = try ChatStore.open(files: f.service.files, key: f.key).store
        XCTAssertEqual(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: disk)?.prompt, restored.prompt)
        XCTAssertEqual(try disk.calls.requests().filter { $0.kind == "personal" }.count, 1)
        let foreignKey = try OrgKey(server: f.key.server.description, accountID: "other", orgID: f.key.orgId)
        let foreign = TabState(route: .ask(foreignKey, agentID: CallJSON.agent)), other = tabs.askModel(foreign)
        XCTAssertFalse(other.readable); XCTAssertEqual(other.prompt, ""); XCTAssertTrue(other.history.isEmpty)
        XCTAssertFalse(session.hasProcess)
    }

    func testPersonalAskCopyChecksExactResultVersionAndAccessWithoutSendingOrCreatingForward() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), host = host()
        let session = try XCTUnwrap(tabs.open(.ask(OrgKey(f.key), agentID: CallJSON.agent), from: host))
        let form = tabs.askModel(try XCTUnwrap(session.tabState))
        let id = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased()
        let wire = CallJSON.wire(CallJSON.request(id, state: "finished", version: 3, runId: run,
            result: ["request_id": id, "run_id": run, "text": "# Available result", "truncated": false, "delivered_at": "2026-10-08T12:00:00Z"], owner: CallJSON.boris, initiator: f.key.accountId))
        try write(f.store.queue) { try ChatCallStore.apply($0, wire, onThisDevice: false) }
        let shown = try XCTUnwrap(form.history.first)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(form.copy(shown, to: board)); XCTAssertEqual(board.string(forType: .string), "# Available result")
        try f.write("UPDATE requests SET version = version + 1")
        board.clearContents(); board.setString("untouched", forType: .string)
        XCTAssertFalse(form.copy(shown, to: board)); XCTAssertEqual(board.string(forType: .string), "untouched")
        let updated = try XCTUnwrap(form.history.first)
        try f.store.putRightsInDoubt()
        XCTAssertFalse(form.copy(updated, to: board)); XCTAssertEqual(board.string(forType: .string), "untouched")
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertEqual(host.popups.sessions.count, 1)
        XCTAssertTrue(host.drafts.drafts.isEmpty)
    }

    func testNewChannelUsesOneDraftAndReplacesItsRouteOnceIncludingCrashBeforeSubmittedSave() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), first = host(), second = host()
        tabs.newChannel(key: f.key, teamID: teamID, from: first)
        let session = try XCTUnwrap(first.popups.sessions.first), state = try XCTUnwrap(session.tabState), form = tabs.channelModel(state)
        tabs.newChannel(key: f.key, teamID: teamID, from: second)
        XCTAssertEqual(first.popups.sessions.count + second.popups.sessions.count, 2)
        form.fields.name = String(repeating: "invalid", count: 20)
        form.create(); XCTAssertNotNil(form.problem); XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        XCTAssertFalse(second.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(second.active)))
        form.fields.name = "Saved channel"
        form.create(); form.create()
        XCTAssertNil(form.problem)
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "channel.create" }.count, 1)
        XCTAssertFalse(first.popups.isPresented, "A successful explicit create closes its popup before server sync")
        XCTAssertNotNil(first.channelTab(ChannelRef(f.key, channel: form.fields.channelID)))
        var fields = form.fields; fields.submitted = false
        let restoredState = TabState(route: state.route); restoredState.edit(.newChannelForm(fields))
        let restored = tabs.channelModel(restoredState)
        XCTAssertFalse(restored.canCreate, "Persisted operation ID must find the already queued create")
        let card = ChatChannelCard(channelId: fields.channelID, teamId: teamID, name: fields.name, archived: false, version: 1)
        try write(f.store.queue) { _ = try ChatChannels.write($0, card) }
        try await wait { org.visibleChannel(fields.channelID) != nil }
        form.reconcile(); form.reconcile()
        XCTAssertTrue(state.isClosed)
        XCTAssertNil(tabs.router.owner(of: session.id))
        XCTAssertNotNil(first.channelTab(ChannelRef(f.key, channel: fields.channelID)))
        XCTAssertNil(second.channelTab(ChannelRef(f.key, channel: fields.channelID)))
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "channel.create" }.count, 1)
    }

    func testChannelAndForwardCancelDiscardRetainedFormsWithoutQueueing() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), host = host()
        tabs.newChannel(key: f.key, teamID: teamID, from: host)
        let channelState = try XCTUnwrap(host.popups.sessions.first?.tabState)
        let channelForm = tabs.channelModel(channelState)
        channelForm.fields.name = "Unfinished channel"
        host.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(host.drafts.drafts.count, 1)
        tabs.newChannel(key: f.key, teamID: teamID, from: host)
        XCTAssertEqual(tabs.channelModel(channelState).fields.name, "Unfinished channel")
        tabs.cancel(channelState)
        XCTAssertTrue(channelState.isClosed)
        XCTAssertTrue(host.drafts.drafts.isEmpty)
        tabs.newChannel(key: f.key, teamID: teamID, from: host)
        let fresh = try XCTUnwrap(host.popups.sessions.first?.tabState)
        XCTAssertEqual(tabs.channelModel(fresh).fields.name, "")
        tabs.cancel(fresh)

        let route = ToolRoute.forward(sourceSessionID: UUID(), answerSnapshotID: UUID())
        let forwardState = try XCTUnwrap(tabs.open(route, from: host)?.tabState)
        forwardState.edit(.forwardForm(.init(snapshot: "Fixed snapshot", markdown: "Edited answer", destination: OrgKey(f.key))))
        _ = tabs.forwardModel(forwardState)
        host.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(host.drafts.drafts.count, 1)
        _ = tabs.open(route, from: host)
        XCTAssertEqual(tabs.forwardModel(forwardState)?.text, "Edited answer")
        tabs.cancel(forwardState)
        XCTAssertTrue(forwardState.isClosed)
        XCTAssertTrue(host.drafts.drafts.isEmpty)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testChannelAskDraftRestoresTextContextAndDoubleSendCreatesOneChannelRequest() async throws {
        let (f, _) = try await fixture()
        let id = UUID().uuidString.lowercased()
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: [
            "message_id": id, "channel_id": channel, "author_account_id": f.key.accountId, "text": "Question", "revision": 1, "seq": 1, "created_at": "2026-10-08T12:00:00Z"]))
        try write(f.store.queue) { _ = try ChatMessages.write($0, wire) }
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store)
        model.beginAsk(.init(messageId: id, agentId: CallJSON.agent, address: "billing@boris", text: "Question", root: id))
        let form = try XCTUnwrap(model.channelAsk); form.fields.text = "Edited channel question"; form.fields.chosen = [id]
        let restarted = ChatChannelModel(key: f.key, channel: channel); restarted.service = f.service; restarted.follow(f.store); restarted.restoreAsk()
        let restored = try XCTUnwrap(restarted.channelAsk)
        XCTAssertEqual(restored.fields.text, form.fields.text); XCTAssertEqual(restored.fields.chosen, [id])
        let agents = try f.store.channelAgents(channel)
        restored.send(agents: agents); restored.send(agents: agents)
        XCTAssertNil(restored.problem)
        let commands = try f.store.outbox.commands().filter { $0.type == "request.create_in_channel" }
        XCTAssertEqual(commands.count, 1)
        let args = ChatService.args(try XCTUnwrap(commands.first))
        XCTAssertEqual(args["channel_id"]?.string, channel)
        XCTAssertEqual(args["text"]?.string, "Edited channel question")
        XCTAssertEqual(args["context"], .array([.object(["message_id": .string(id), "revision": .number(1)])]))
        try f.write("UPDATE teams SET mine = 0")
        let saved = try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store)
        XCTAssertNil(saved)
        try f.write("UPDATE teams SET mine = 1")
        restored.fields.text = "A stale view cannot restore revoked text"
        XCTAssertNotNil(restored.problem)
        XCTAssertNil(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store))
    }

    func testDifferentChannelAskPreservesKeptDraftUntilInlineReplacement() async throws {
        let (f, _) = try await fixture()
        let model = ChatChannelModel(key: f.key, channel: channel); model.service = f.service; model.follow(f.store)
        let confirmation = ConfirmationCoordinator(); model.confirmation = confirmation; model.tabID = UUID()
        let first = ChatChannelAsk.Offer(messageId: UUID().uuidString, agentId: CallJSON.agent,
            address: "billing@boris", text: "First question", root: UUID().uuidString)
        let second = ChatChannelAsk.Offer(messageId: UUID().uuidString, agentId: CallJSON.agent,
            address: "billing@boris", text: "Second question", root: UUID().uuidString)
        model.beginAsk(first)
        let original = try XCTUnwrap(model.channelAsk)
        XCTAssertTrue(original.replacement === confirmation)
        original.fields.text = "Keep my edits"; original.fields.chosen = [first.root, "extra-context"]; original.expanded = false
        let kept = original.fields
        model.beginAsk(second)
        XCTAssertTrue(model.channelAsk === original); XCTAssertTrue(original.expanded)
        XCTAssertEqual(original.fields, kept); XCTAssertTrue(original.replacement.isAwaiting)
        original.replacement.shown(true); original.replacement.cancel()
        XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store), kept)

        // Opening an offer before the view's restore task must find disk edits too.
        let reopened = ChatChannelModel(key: f.key, channel: channel); reopened.service = f.service; reopened.follow(f.store)
        reopened.beginAsk(second)
        let form = try XCTUnwrap(reopened.channelAsk)
        XCTAssertEqual(form.fields, kept); XCTAssertTrue(form.replacement.isAwaiting)
        form.replacement.shown(true); form.fields.text = "A later edit invalidates this decision"
        form.replacement.confirm()
        XCTAssertEqual(form.replacement.phase, .invalidated)
        XCTAssertEqual(form.fields.offer, first)
        reopened.beginAsk(second)
        form.replacement.shown(true); form.replacement.confirm(); form.replacement.confirm()
        try await wait { form.replacement.phase == .completed }
        XCTAssertEqual(form.fields.offer, second); XCTAssertEqual(form.fields.text, second.text)
        XCTAssertEqual(form.fields.chosen, [second.root]); XCTAssertNotEqual(form.fields.requestID, kept.requestID)
        XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store), form.fields)
        model.beginAsk(first) // This older model still holds the replaced request ID.
        XCTAssertEqual(model.channelAsk?.fields, form.fields)
        XCTAssertTrue(try XCTUnwrap(model.channelAsk).replacement.isAwaiting)
        XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store), form.fields)
        confirmation.shown(true)
        try f.store.putRightsInDoubt()
        confirmation.confirm()
        XCTAssertEqual(confirmation.phase, .invalidated)
        XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + channel, store: f.store), form.fields)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testClosingForwardDuringExplicitSendKeepsOperationAndClosesOnSuccessWithoutDuplicatePost() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org)
        let host = makeTestStore(); hosts.append(host)
        let source = try XCTUnwrap(host.active?.activeSession); source.agent = .claudeCode
        let processes = AnswerProcessFixture(); try processes.bind(source, conversation: UUID().uuidString.lowercased())
        tabs.forward(session: source, store: host, inspector: processes.inspector, reader: { _, _, _ in "Saved answer" })
        try await wait { host.popups.sessions.contains { if case .forward = $0.toolRoute { true } else { false } } }
        let session = try XCTUnwrap(host.popups.sessions.first { if case .forward = $0.toolRoute { true } else { false } })
        let state = try XCTUnwrap(session.tabState), model = try XCTUnwrap(tabs.forwardModel(state))
        model.text = "Keep this edited answer"; model.channels = [.init(id: channel, title: "billing")]; model.channel = channel
        await model.refreshPresentation()
        let gate = Gate(), entered = expectation(description: "post preflight"); gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { _, _ in
            entered.fulfill(); gate.pass()
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let task = Task { await model.send() }
        await fulfillment(of: [entered], timeout: 5)
        let owner = try XCTUnwrap(tabs.router.owner(of: session.id))
        XCTAssertTrue(host.tabCloseCoordinator.prepare([session])); host.closeTab(session, in: owner.workspace)
        let restoredState = try XCTUnwrap(tabs.open(state.route, from: host)?.tabState)
        let restored = try XCTUnwrap(tabs.forwardModel(restoredState))
        XCTAssertTrue(restored === model)
        XCTAssertNil(restored.attemptID); XCTAssertEqual(restored.text, "Keep this edited answer")
        XCTAssertTrue(restored.sending)
        XCTAssertFalse(restored.canSend)
        gate.open(); await task.value
        await restored.send(); await restored.send(); await restored.sendAsUser()
        XCTAssertEqual(try f.store.outbox.commands().filter { $0.type == "message.post_from_session" }.count, 1)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
        XCTAssertNotNil(restored.attemptID)
        XCTAssertTrue(state.isClosed)
        XCTAssertFalse(host.popups.isPresented)
        XCTAssertNil(tabs.router.owner(of: session.id))
        XCTAssertTrue(host.drafts.drafts.isEmpty)
    }

    func testAskCancelDeletesKeptDraftAndSendReceiptFollowsProgressWithoutCancellingOnClose() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), host = host()
        let route = ToolRoute.ask(OrgKey(f.key), agentID: CallJSON.agent)
        let state = try XCTUnwrap(tabs.open(route, from: host)?.tabState), form = tabs.askModel(state)
        form.prompt = "A kept question"
        host.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store)?.prompt, form.prompt)
        _ = tabs.open(route, from: host)
        tabs.cancel(state)
        XCTAssertTrue(state.isClosed)
        XCTAssertNil(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store))
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        let freshState = try XCTUnwrap(tabs.open(route, from: host)?.tabState), fresh = tabs.askModel(freshState)
        XCTAssertEqual(fresh.prompt, "")
        fresh.prompt = "Explicit request"
        fresh.send(); fresh.send()
        let sent = try XCTUnwrap(fresh.sentRequest)
        XCTAssertEqual(fresh.receiptTitle, "Sent — Open request")
        XCTAssertTrue(host.popups.isPresented)
        let commands = try f.store.outbox.commands()
        XCTAssertEqual(commands.count, 1)
        try f.write("UPDATE requests SET state = 'running', version = version + 1 WHERE request_id = ?", [sent.requestId])
        try await wait { fresh.sentRequest?.state == .running }
        host.popups.dismiss(reason: .dismiss)
        XCTAssertEqual(try f.store.outbox.commands(), commands)
        XCTAssertEqual(fresh.sentRequest?.state, .running)
        _ = tabs.open(route, from: host)
        fresh.closeReceipt()
        XCTAssertFalse(host.popups.isPresented)
        XCTAssertEqual(try f.store.outbox.commands(), commands)
        XCTAssertEqual(try f.store.calls.requests().first { $0.requestId == sent.requestId }?.state, .running)
        let nextState = try XCTUnwrap(tabs.open(route, from: host)?.tabState), next = tabs.askModel(nextState)
        XCTAssertEqual(next.receiptTitle, "Ask agent")
        XCTAssertEqual(next.prompt, "")
        XCTAssertNil(next.sentRequest)
        next.prompt = "Second explicit request"
        XCTAssertTrue(next.canSend)
        next.send()
        XCTAssertNotEqual(next.sentRequest?.requestId, sent.requestId)
        XCTAssertEqual(try f.store.outbox.commands().count, 2)
        XCTAssertEqual(try f.store.calls.requests().first { $0.requestId == sent.requestId }?.state, .running)
    }

    func testClosingOlderAskReceiptPreservesAnotherWindowsSavedQuestion() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org), first = host(), second = host()
        let route = ToolRoute.ask(OrgKey(f.key), agentID: CallJSON.agent)
        let firstState = try XCTUnwrap(tabs.open(route, from: first)?.tabState)
        let older = tabs.askModel(firstState)
        older.prompt = "First request from window A"
        older.send()
        let sent = try XCTUnwrap(older.sentRequest)
        let secondState = try XCTUnwrap(tabs.open(route, from: second)?.tabState)
        let receipt = tabs.askModel(secondState)
        XCTAssertEqual(receipt.sentRequest?.requestId, sent.requestId)
        receipt.closeReceipt()
        XCTAssertNil(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store))

        let newState = try XCTUnwrap(tabs.open(route, from: second)?.tabState)
        let newer = tabs.askModel(newState)
        newer.prompt = "Keep window B's new unsent question"
        let saved = try XCTUnwrap(ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store))
        XCTAssertNotEqual(saved.requestID, sent.requestId)
        let commands = try f.store.outbox.commands()
        older.closeReceipt()
        XCTAssertTrue(firstState.isClosed)
        XCTAssertEqual(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store), saved)

        // The new model already saved its edits, so dismissal has no dirty
        // value to rewrite. A fresh window must still recover the whole draft.
        second.popups.dismiss(reason: .dismiss)
        let restartedState = TabState(route: route), restarted = tabs.askModel(restartedState)
        XCTAssertEqual(restarted.prompt, saved.prompt)
        XCTAssertNil(restarted.sentRequest)
        XCTAssertEqual(try ChatCompositionDrafts.read(PersonalAskDraft.self, id: "ask:" + CallJSON.agent, store: f.store), saved)
        XCTAssertEqual(try f.store.outbox.commands(), commands)
        XCTAssertEqual(try f.store.calls.requests().first { $0.requestId == sent.requestId }, sent)
    }

    func testForwardSnapshotDeduplicatesBeforeReadRetainsEditsAndFollowsLiveSourceOwner() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org)
        let sourceStore = makeTestStore(); hosts.append(sourceStore)
        let source = try XCTUnwrap(sourceStore.active?.activeSession); source.agent = .claudeCode
        let processes = AnswerProcessFixture(); try processes.bind(source, conversation: UUID().uuidString.lowercased())
        let gate = Gate(), entered = expectation(description: "one read"); gate.close(); defer { gate.open() }
        let reader: AgentAnswerSource.Reader = { _, _, _ in entered.fulfill(); gate.pass(); return "Original snapshot" }
        tabs.forward(session: source, store: sourceStore, inspector: processes.inspector, reader: reader)
        tabs.forward(session: source, store: sourceStore, inspector: processes.inspector, reader: reader)
        await fulfillment(of: [entered], timeout: 5)
        gate.open()
        try await wait { sourceStore.popups.sessions.contains { if case .forward = $0.toolRoute { true } else { false } } }
        let forward = try XCTUnwrap(sourceStore.popups.sessions.first { if case .forward = $0.toolRoute { true } else { false } })
        let state = try XCTUnwrap(forward.tabState), model = try XCTUnwrap(tabs.forwardModel(state))
        model.text = "Saved Markdown edits"
        let other = host(); _ = other.addEmptyWorkspace()
        XCTAssertTrue(other.handleTabDrop(droppedId: source.id, in: try XCTUnwrap(other.active)))
        XCTAssertTrue(model.sourceIsCurrent(), "Moving a live source changes its owner, not its authority")
        source.answerCheckProblem = .inspectionTimeout
        XCTAssertFalse(model.sourceIsCurrent())
        XCTAssertTrue(model.sourceCanRetry(), "A live Forward retains its explicit retry after a scan timeout")
        source.answerCheckProblem = nil
        tabs.forward(session: source, store: other, inspector: processes.inspector, reader: { _, _, _ in "New last answer" })
        try await wait { self.hosts.flatMap { $0.popups.sessions }.filter { if case .forward = $0.toolRoute { true } else { false } }.count == 2 }
        XCTAssertEqual(model.snapshot, "Original snapshot"); XCTAssertEqual(model.text, "Saved Markdown edits")
        let saved = try JSONDecoder().decode(TabDraft.self, from: JSONEncoder().encode(XCTUnwrap(state.draft)))
        let restoredState = TabState(route: saved.route); restoredState.draft = saved
        let restored = try XCTUnwrap(tabs.forwardModel(restoredState))
        XCTAssertTrue(restored.sourceIsCurrent()); XCTAssertEqual(restored.text, "Saved Markdown edits")
        let restartedTabs = self.tabs(f, org)
        let restartedState = TabState(route: saved.route); restartedState.draft = saved
        XCTAssertFalse(try XCTUnwrap(restartedTabs.forwardModel(restartedState)).sourceIsCurrent())
        let owner = try XCTUnwrap(tabs.router.owner(of: source.id))
        owner.store.closeTab(source, in: owner.workspace)
        XCTAssertFalse(restored.sourceIsCurrent())
        XCTAssertFalse(model.sourceIsCurrent())
        source.answerCheckProblem = .inspectionTimeout
        XCTAssertFalse(restored.sourceCanRetry(), "A timeout cannot authorize a closed source")
        XCTAssertFalse(model.sourceCanRetry())
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testForwardRejectsPIDOrConversationReplacementDuringSendPreflight() async throws {
        for change in ["pid", "conversation"] {
            let (f, org) = try await fixture(), tabs = tabs(f, org)
            let host = makeTestStore(); hosts.append(host)
            let source = try XCTUnwrap(host.active?.activeSession); source.agent = .claudeCode
            let processes = AnswerProcessFixture(); try processes.bind(source, conversation: UUID().uuidString.lowercased())
            tabs.forward(session: source, store: host, inspector: processes.inspector, reader: { _, _, _ in "Bound source answer" })
            try await wait { host.popups.sessions.contains { if case .forward = $0.toolRoute { true } else { false } } }
            let state = try XCTUnwrap(host.popups.sessions.first { if case .forward = $0.toolRoute { true } else { false } }?.tabState)
            let model = try XCTUnwrap(tabs.forwardModel(state))
            model.channels = [.init(id: channel, title: "billing")]; model.channel = channel
            await model.refreshPresentation()
            let gate = Gate(), entered = expectation(description: change); gate.close()
            ChatStubProtocol.reset { _, _ in
                entered.fulfill(); gate.pass()
                return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
            }
            let task = Task { await model.send() }
            await fulfillment(of: [entered], timeout: 5)
            if change == "pid" { processes.add(AnswerProcessFixture.claude, parent: AnswerProcessFixture.shell, name: "claude", trusted: true, start: 101) }
            else { try processes.bind(source, conversation: UUID().uuidString.lowercased()) }
            gate.open(); await task.value
            XCTAssertNotNil(model.problem); XCTAssertFalse(model.canSend)
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        }
    }

    func testDiskDraftReopenAndScopeRevocationClearOnlyMatchingSnapshots() async throws {
        let (f, org) = try await fixture(), tabs = tabs(f, org)
        let archive = root.appendingPathComponent("drafts.json"), host = host(drafts: DraftRepository(fileURL: root.appendingPathComponent("drafts.json")))
        let state = try XCTUnwrap(tabs.open(.forward(sourceSessionID: UUID(), answerSnapshotID: UUID()), from: host)?.tabState)
        state.edit(.forwardForm(.init(snapshot: "Original", markdown: "Saved changes", destination: OrgKey(f.key))))
        let model = try XCTUnwrap(tabs.forwardModel(state)); try tabs.save(state)
        let saved = try XCTUnwrap(DraftRepository(fileURL: archive).draft(try XCTUnwrap(state.draft?.id)))
        XCTAssertEqual(saved, state.draft)
        let reopened = TabState(route: saved.route); reopened.draft = saved
        let restored = try XCTUnwrap(self.tabs(f, org).forwardModel(reopened))
        XCTAssertEqual(restored.snapshot, "Original"); XCTAssertEqual(restored.text, "Saved changes"); XCTAssertFalse(restored.canSend)
        let foreign = try OrgKey(server: f.key.server.description, accountID: "another-account", orgID: f.key.orgId)
        let other = try XCTUnwrap(tabs.open(.forward(sourceSessionID: UUID(), answerSnapshotID: UUID()), from: host)?.tabState)
        other.edit(.forwardForm(.init(snapshot: "Other", markdown: "Other edits", destination: foreign))); try tabs.save(other)
        let otherID = try XCTUnwrap(other.draft?.id)
        tabs.revoke(f.key)
        XCTAssertNil(state.draft); XCTAssertNil(state.forwardForm); XCTAssertFalse(model.active)
        let disk = DraftRepository(fileURL: archive)
        XCTAssertNil(disk.draft(saved.id)); XCTAssertNotNil(disk.draft(otherID))
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }
}
