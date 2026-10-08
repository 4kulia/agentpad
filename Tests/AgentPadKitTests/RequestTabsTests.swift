import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class RequestTabsTests: XCTestCase {
    private typealias Fixture = ChatChannelExecutionTests.Fixture
    private var root: URL!
    private var fixtures: [Fixture] = []
    private var hosts: [WorkspaceStore] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let messageID = "f5000000-0000-4000-8000-000000000002"
    private let requestID = "f5000000-0000-4000-8000-000000000003"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("request-tabs-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        hosts.forEach { $0.terminate() }; hosts = []
        for f in fixtures { f.sender?.hold(); await f.service.disconnect() }
        fixtures = []; ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture(executor: TeamAgentRunner? = nil) async throws -> Fixture {
        let f = try await Fixture(root: root.appendingPathComponent(UUID().uuidString), executor: executor)
        fixtures.append(f)
        f.service.serverCapabilities[f.key.server] = ["chat.channel_ux1", "chat.attachments_context", "chat.attachments"]
        f.service.isServerKnown = { _, _ in true }
        try f.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
        try write(f.journal.queue) { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
        try f.move("awaiting_decision", 2); try f.serve()
        return f
    }
    private func host() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            engineFactory: { XCTFail("Request created a terminal engine"); return TestEngine() }, peerStores: { [weak self] in self?.hosts ?? [] })
        hosts.append(store); return store
    }
    private func write(_ queue: DatabaseQueue, _ body: (Database) throws -> Void) throws { try queue.write(body) }
    private func tab(_ f: Fixture, versions: ClaudeVersionApprovals = ClaudeVersionApprovals()) async throws -> (RequestTabs, Session, RequestTabModel) {
        let host = host(), router = TabRouter(); router.stores = { [host] }
        let tabs = RequestTabs(router: router, chat: f.service, team: f.teamService, versions: versions)
        let session = try XCTUnwrap(tabs.open(requestID, scope: .server(OrgKey(f.key)), from: host))
        let state = try XCTUnwrap(session.tabState)
        state.confirmation.canShow = { true }
        let model = tabs.model(state); await model.load()
        return (tabs, session, model)
    }
    private func wait(_ predicate: () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try predicate(), file: file, line: line)
    }
    private func accept(_ action: RequestTabModel.Action, _ model: RequestTabModel, _ session: Session,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try XCTUnwrap(session.tabState?.confirmation)
        XCTAssertTrue(model.confirm(action), file: file, line: line)
        c.shown(true); c.confirm(); c.confirm()
        try await wait { !c.isExecuting }
        XCTAssertEqual(c.phase, .completed, file: file, line: line)
    }
    private func decisions(_ f: Fixture) throws -> [ChatCommandRecord] { try f.commands().filter { $0.type == "request.decide" } }

    func testOneAddressAcrossEntriesTransferScopeAndRestoreNeverRestoresConsent() async throws {
        let f = try await fixture(), (tabs, session, model) = try await tab(f)
        tabs.router.stores = { [weak self] in self?.hosts ?? [] }
        let state = try XCTUnwrap(session.tabState)
        model.reason = "A saved reason, including invalid unfinished input"
        XCTAssertTrue(model.confirm(.decline)); state.confirmation.shown(true)
        let other = host(), workspace = try XCTUnwrap(other.active)
        XCTAssertTrue(tabs.open(requestID, scope: .server(OrgKey(f.key)), from: other) === session)
        XCTAssertTrue(tabs.open(requestID, callScope: TeamCallScope(f.key), from: other) === session)
        XCTAssertTrue(other.handleTabDrop(droppedId: session.id, in: workspace))
        XCTAssertTrue(tabs.model(state) === model)
        XCTAssertEqual(state.confirmation.phase, .invalidated)
        XCTAssertEqual(model.reason, "A saved reason, including invalid unfinished input")
        XCTAssertFalse(tabs.open(requestID, scope: .local, from: other) === session)
        let otherAccount = try OrgKey(server: f.key.server.description, accountID: "other", orgID: f.key.orgId)
        let foreign = try XCTUnwrap(tabs.open(requestID, scope: .server(otherAccount), from: other)?.tabState)
        XCTAssertFalse(tabs.model(foreign).readable)
        let draft = try JSONDecoder().decode(TabDraft.self, from: JSONEncoder().encode(XCTUnwrap(state.draft)))
        let restored = TabState(route: draft.route); restored.draft = draft
        let restoredModel = tabs.model(restored)
        XCTAssertEqual(restoredModel.reason, model.reason)
        XCTAssertEqual(restored.confirmation.phase, .idle)
        XCTAssertTrue(try decisions(f).isEmpty)
        XCTAssertFalse(session.hasProcess)
    }

    func testPersonalRequestDecisionsUseD9AndInlineReasonWithoutChannelContent() async throws {
        for allow in [false, true] {
            let f = try await fixture()
            try f.write("UPDATE requests SET kind = 'personal', channel_id = NULL, thread_root_id = NULL")
            f.calls.reload()
            let (_, session, model) = try await tab(f)
            XCTAssertNotNil(model.incoming)
            model.reason = "Review the scope first"
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
            try await accept(allow ? .allow : .decline, model, session)
            let commands = try decisions(f)
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(try f.journal.approvals().count, allow ? 1 : 0)
            if !allow { XCTAssertEqual(commands.first.map { ChatService.args($0)["reason"] }, .string("Review the scope first")) }
            XCTAssertTrue(ChatStubProtocol.seen.isEmpty)
        }
    }

    func testChannelOwnerCanStopFromAnotherMacButCannotDecideThere() async throws {
        for state in ["starting", "running"] {
            let f = try await fixture()
            try f.move(state, 3, run: "run", here: false)
            let (_, session, model) = try await tab(f)
            XCTAssertFalse(try XCTUnwrap(model.request).onThisDevice)
            XCTAssertTrue(model.canStop, state)
            model.stop()
            XCTAssertNil(session.tabState?.message)
            let commands = try f.commands().filter { $0.type == "request.stop" }
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first.map { ChatService.args($0)["request_id"] }, .string(requestID))

            try f.move("awaiting_decision", 4, here: false)
            XCTAssertFalse(model.canStop)
            XCTAssertFalse(model.canDecide)
            XCTAssertFalse(model.confirm(.allow))
            XCTAssertFalse(model.confirm(.decline))
            model.stop()
            XCTAssertEqual(try f.commands().filter { $0.type == "request.stop" }.count, 1)
        }
    }

    func testChannelMemberReadsPublicRequestStatusAndActivityWithoutOwnerActions() async throws {
        let f = try await fixture()
        try f.move("running", 3, run: "run", here: false)
        try f.write("UPDATE members SET role = 'member' WHERE account_id = ?", [f.key.accountId])
        try f.write("UPDATE requests SET owner_account_id = ?, initiator_account_id = ?", [CallJSON.boris, CallJSON.boris])
        f.calls.reload()
        let (_, _, model) = try await tab(f)
        f.service.receiveChannelActivity(org: f.key.orgId, type: "run.activity",
            body: .object(["request_id": .string(requestID), "text": .string("Reading files")]))
        XCTAssertTrue(model.readable)
        XCTAssertEqual(model.request?.state, .running)
        XCTAssertEqual(model.activity, "Reading files")
        XCTAssertNil(model.incoming); XCTAssertNil(model.outgoing)
        XCTAssertNil(model.result)
        XCTAssertTrue(model.folders.isEmpty); XCTAssertTrue(model.versions.isEmpty)
        XCTAssertFalse(model.canStop); XCTAssertFalse(model.canDecide)
        for action in [RequestTabModel.Action.allow, .decline, .publish, .withhold] {
            XCTAssertFalse(model.confirm(action))
        }
        model.stop()
        XCTAssertTrue(try f.commands().isEmpty)

        try f.write("UPDATE requests SET kind = 'personal', channel_id = NULL")
        XCTAssertFalse(model.readable, "Personal requests stay private")
        XCTAssertNil(model.activity)
        try f.write("UPDATE requests SET kind = 'channel', channel_id = ?", [channel])
        XCTAssertTrue(model.readable)
        try f.write("DELETE FROM team_members WHERE account_id = ?", [f.key.accountId])
        try f.write("UPDATE teams SET mine = 0")
        XCTAssertFalse(model.readable, "Channel access is checked on every read")
        XCTAssertNil(model.activity)
    }

    func testPersonalAnswerPrefersFullLocalTextAndLabelsTruncatedFallback() async throws {
        let f = try await fixture()
        try f.move("running", 3, run: "run")
        let now = ChatCallStore.timestamp(Date())
        try f.write("UPDATE requests SET kind = 'personal', state = 'finished', channel_id = NULL, thread_root_id = NULL, initiator_account_id = ?, created_at = ?, updated_at = ?",
            [f.key.accountId, now, now])
        let full = String(repeating: "Full local answer. ", count: 10_000)
        let delivered = String(full.prefix(100))
        try f.store.calls.setLocal(requestID, text: full, log: nil, runId: "run")
        try write(f.store.queue) { db in
            try ChatCallStore.apply(db, result: ChatCallResult(requestId: requestID, runId: "run", text: delivered,
                truncated: true, threadId: nil, deliveredAt: ChatCallStore.timestamp(Date())), requestId: requestID)
        }
        f.calls.reload()
        let (_, _, model) = try await tab(f)
        XCTAssertNotNil(model.incoming); XCTAssertNotNil(model.outgoing)
        XCTAssertTrue(model.result == full, "The Request view and Copy as Markdown must use the complete local answer")
        XCTAssertEqual(model.resultTitle, "Answer")

        try f.write("UPDATE requests SET local_text = NULL")
        f.calls.reload()
        XCTAssertEqual(model.result, delivered)
        XCTAssertEqual(model.resultTitle, "Answer · truncated")
        try f.write("UPDATE results SET text = '', trimmed = 1")
        f.calls.reload()
        XCTAssertEqual(model.result, "[The answer is no longer kept on this Mac: history limit.]")
        XCTAssertEqual(model.resultTitle, "Answer · truncated")
    }

    func testStaleAllowAndDeclineRejectExecutorExpiryAccessRevisionContextAndSettings() async throws {
        for action in [RequestTabModel.Action.allow, .decline] {
            for change in ["executor", "expiry", "access", "version", "context", "settings", "generation", "leave"] {
                let f = try await fixture(), (_, session, model) = try await tab(f)
                let c = try XCTUnwrap(session.tabState?.confirmation)
                XCTAssertTrue(model.confirm(action), "\(action), \(change)"); c.shown(true)
                switch change {
                case "executor": try f.move("awaiting_decision", 3, here: false)
                case "expiry": c.now = { Date().addingTimeInterval(7200) }
                case "access": try f.write("DELETE FROM team_members WHERE account_id = ?", [f.key.accountId])
                case "version": try f.move("awaiting_decision", 3)
                case "context": try f.write("DELETE FROM request_contents")
                case "settings": f.agent.maxTurns += 1
                case "generation": try f.store.finishGeneration("g2")
                default: session.tabState?.leave()
                }
                c.confirm(); await Task.yield()
                XCTAssertEqual(c.phase, .invalidated, change)
                XCTAssertTrue(try decisions(f).isEmpty, change)
                XCTAssertTrue(try f.journal.approvals().isEmpty, change)
            }
        }
    }

    func testChangedContextOrAttachmentOnAllowRequiresFreshReview() async throws {
        for attachment in [false, true] {
            let f = try await fixture()
            var content = f.content()
            if attachment {
                try f.write("UPDATE requests SET conditions_version = 2")
                content.attachments = [.init(file: .init(attachmentId: "file", position: 0, name: "reviewed.txt", mime: "text/plain", size: 4, hasPreview: false),
                    messageId: messageID, revision: 2, sha256: String(repeating: "a", count: 64))]
            }
            try f.serve(content)
            let (_, session, model) = try await tab(f), c = try XCTUnwrap(session.tabState?.confirmation)
            XCTAssertTrue(model.confirm(.allow)); c.shown(true)
            if attachment { content.attachments?[0].sha256 = String(repeating: "b", count: 64) }
            else { content.context?[0].text = "Changed after review" }
            try f.serve(content)
            c.confirm(); try await wait { !c.isExecuting }
            guard case .failed = c.phase else { XCTFail("Changed terms must stay for review"); continue }
            XCTAssertTrue(try decisions(f).isEmpty)
            XCTAssertTrue(try f.journal.approvals().isEmpty)
            XCTAssertEqual(model.review()?.content, content, "the next review shows the new snapshot")
        }
    }

    func testAllowAndDeclineRaceServerEventAndEachOtherWithoutSecondDecision() async throws {
        for finalState in ["declined", "approved", "expired"] {
            let f = try await fixture(), (_, session, model) = try await tab(f)
            let c = try XCTUnwrap(session.tabState?.confirmation), gate = Gate(); gate.close(); defer { gate.open() }
            try f.serve(gate: gate)
            XCTAssertTrue(model.confirm(.allow)); c.shown(true); c.confirm(); c.confirm()
            XCTAssertFalse(model.confirm(.decline))
            try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/content") == true } }
            try f.move(finalState, 4)
            gate.open(); try await wait { !c.isExecuting }
            XCTAssertTrue(try decisions(f).isEmpty, finalState)
            XCTAssertTrue(try f.journal.approvals().isEmpty, finalState)
        }
        for action in [RequestTabModel.Action.allow, .decline] {
            let f = try await fixture(), (_, session, model) = try await tab(f)
            model.reason = "Not this request"
            try await accept(action, model, session)
            XCTAssertNil(session.tabState?.draft)
            let duplicate = await f.owner.decideChannel(f.key, requestId: requestID, allow: action != .allow, reason: "late")
            XCTAssertNil(duplicate)
            XCTAssertEqual(try decisions(f).count, 1)
            XCTAssertEqual(try f.journal.approvals().count, action == .allow ? 1 : 0)
            XCTAssertEqual(try decisions(f).first.map { ChatService.args($0)["allow"] }, .bool(action == .allow))
            try f.move(action == .allow ? "approved" : "declined", 4)
            XCTAssertFalse(model.confirm(.allow)); XCTAssertFalse(model.confirm(.decline))
        }
    }

    func testPreviewPublishWithholdAndServerEventRace() async throws {
        for choice in [RequestTabModel.Action.publish, .withhold] {
            for serverFirst in [false, true] {
                let f = try await fixture(); _ = try await f.finish()
                let (_, session, model) = try await tab(f), c = try XCTUnwrap(session.tabState?.confirmation)
                XCTAssertNotNil(model.result)
                XCTAssertTrue(model.confirm(choice)); c.shown(true)
                XCTAssertFalse(model.confirm(choice == .publish ? .withhold : .publish))
                if serverFirst { try f.write("UPDATE requests SET publication = 'published', version = version + 1") }
                c.confirm(); c.confirm(); try await wait { !c.isExecuting }
                let commands = try f.commands().filter { ChatPublication.isDecision($0.type) }
                XCTAssertEqual(commands.count, serverFirst ? 0 : 1)
                if !serverFirst {
                    let duplicate = try f.service.publishChannelResult(f.key, requestId: requestID, publish: choice == .publish)
                    XCTAssertEqual(duplicate.commandId, commands.first?.commandId)
                    let answer = ChatCommandAnswer(events: [], result: .object(["request_id": .string(requestID), "version": .number(9),
                        "publication": .string(choice == .publish ? "published" : "withheld")]))
                    f.service.channelPublicationAnswered(f.key, record: duplicate, outcome: .taken(answer))
                    XCTAssertFalse(model.confirm(choice))
                    XCTAssertEqual(try f.commands().filter { ChatPublication.isDecision($0.type) }.count, 1)
                }
            }
        }
    }

    func testTrustReviewIncludesFutureMembersAndRejectsStaleRightsVersionAndExecutor() async throws {
        for change in ["members", "policy", "channel", "rights", "settings", "executor", "session", "none"] {
            let f = try await fixture(), c = ConfirmationCoordinator()
            XCTAssertTrue(f.service.confirmTrust(f.key, channel: channel, agent: CallJSON.agent, tabID: UUID(), coordinator: c), change)
            XCTAssertTrue(c.consequences.contains("current and future member"))
            c.shown(true)
            switch change {
            case "members": try f.write("DELETE FROM team_members WHERE account_id = ?", [CallJSON.boris])
            case "policy": try write(f.store.queue) { try ChatChannelAgents.writeTrust($0, channel: channel, agent: CallJSON.agent, trust: .init(enabled: true, policyId: "new", executorSessionId: "s-anna")) }
            case "channel": try f.write("UPDATE channels SET version = version + 1")
            case "rights": try f.write("UPDATE meta SET rights_in_doubt = 1")
            case "settings": f.agent.maxTurns += 1
            case "executor": try f.write("UPDATE agent_channels SET executor_session_id = 'another'")
            case "session":
                var connection = try XCTUnwrap(f.service.connection); connection.sessionId = "other"
                try f.service.saveSignIn(connection, token: "test-only")
            default: break
            }
            c.confirm(); c.confirm(); try await wait { !c.isExecuting }
            let commands = try f.commands().filter { $0.type == "agent.channel_trust.set" }
            XCTAssertEqual(commands.count, change == "none" ? 1 : 0, change)
            XCTAssertEqual(c.phase, change == "none" ? .completed : .invalidated, change)
        }
    }

    func testDeleteUsesReviewedRevisionAndWarnsAboutAlreadyTransferredCopies() async throws {
        for changed in [false, true] {
            let f = try await fixture()
            let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: [
                "message_id": messageID, "channel_id": channel, "author_account_id": f.key.accountId, "text": "delete me",
                "revision": 1, "seq": 1, "created_at": "2026-10-07T12:00:00Z", "mentions": []]))
            try write(f.store.queue) { _ = try ChatMessages.write($0, wire) }
            let model = ChatChannelModel(key: f.key, channel: channel), c = ConfirmationCoordinator()
            model.service = f.service; model.follow(f.store); model.confirmation = c; model.tabID = UUID()
            let message = try XCTUnwrap(model.message(messageID))
            XCTAssertTrue(model.requestDelete(message)); c.shown(true)
            XCTAssertTrue(c.consequences.contains("Copies already in the context of a running agent stay"))
            if changed { try f.write("UPDATE messages SET revision = 2, text = 'changed'") }
            c.confirm(); c.confirm(); try await wait { !c.isExecuting }
            let commands = try f.commands().filter { $0.type == "message.delete" }
            XCTAssertEqual(commands.count, changed ? 0 : 1)
            if !changed { XCTAssertEqual(commands.first.map { ChatService.args($0)["expected_revision"] }, .number(1)) }
            XCTAssertEqual(c.phase, changed ? .invalidated : .completed)
        }
    }

    func testFolderRefusalIsOneDecisionAndCreatesNoContinuation() async throws {
        let f = try await fixture(); _ = try await f.allow(); try f.move("running", 5, run: "run")
        let path = root.appendingPathComponent("requested")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let folder = try await f.calls.requestAccess(callId: requestID, path: path.path, reason: "Read another folder")
        let (_, session, model) = try await tab(f)
        XCTAssertEqual(model.folders.map(\.id), [folder.id])
        try await accept(.folder(folder.id, .denied), model, session)
        XCTAssertEqual(f.calls.accessRequests.first { $0.id == folder.id }?.state, .denied)
        XCTAssertFalse(model.confirm(.folder(folder.id, .once)))
        XCTAssertEqual(try f.journal.approvals().count, 1)
    }

    func testD9AndY2InBothOrdersRemainIndependentAndStartOnce() async throws {
        for versionFirst in [false, true] {
            let versions = ClaudeVersionApprovals(), runner = RequestVersionRunner(versions: versions)
            let f = try await fixture(executor: runner), (_, session, model) = try await tab(f, versions: versions)
            if versionFirst {
                var probe = TeamRunRequest(agent: f.agent, prompt: "probe", sessionId: UUID().uuidString, resume: false, callerName: "test", callerProject: nil)
                probe.runToolsCallId = requestID
                let checking = Task { try await runner.checker.prepare(selectedPath: "/fixture/claude", request: probe, onActivity: { _ in }) }
                try await wait { versions.pending.count == 1 }
                try await accept(.version(XCTUnwrap(versions.pending.first?.id), true), model, session)
                _ = try await checking.value
                XCTAssertTrue(try f.journal.approvals().isEmpty, "Y2 must never create D9")
                XCTAssertEqual(runner.starts, 0)
            }
            try await accept(.allow, model, session)
            let approval = try XCTUnwrap(f.journal.approval(f.key, requestId: requestID))
            XCTAssertEqual(runner.starts, 0, "D9 does not bypass the server's start")
            try f.move("starting", 4, run: approval.runId)
            let launching = Task { try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id) }
            if !versionFirst {
                try await wait { versions.pending.count == 1 }
                XCTAssertEqual(runner.starts, 0, "D9 must never grant Y2")
                try await accept(.version(XCTUnwrap(versions.pending.first?.id), true), model, session)
            }
            _ = try await launching.value
            XCTAssertEqual(runner.starts, 1)
            XCTAssertEqual(try f.journal.runs().count, 1)
            XCTAssertEqual(try decisions(f).count, 1)
            do { _ = try await f.service.launcher?.launch(approvalId: approval.id); XCTFail("D9 spent twice") }
            catch { XCTAssertEqual(error as? TeamLauncher.Failure, .alreadyUsed) }
        }
    }
}

@MainActor
private final class RequestVersionRunner: TeamAgentRunner {
    let checker: ClaudeVersionPreflight
    var starts = 0
    init(versions: ClaudeVersionApprovals) {
        checker = ClaudeVersionPreflight(inspect: { path in
            ClaudeExecutable(selectedPath: path, file: .init(resolvedPath: path, device: 1, inode: 1, size: 10, modifiedSeconds: 1, modifiedNanoseconds: 0))
        }, readVersion: { _, _ in "2.1.999" }, approvals: { versions })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        _ = try await checker.prepare(selectedPath: "/fixture/claude", request: request, onActivity: onActivity)
        try request.validateBeforeExecutor?()
        starts += 1
        try onProcessStarted(.init(pid: 900_090, pgid: 900_090, startTime: 90))
        return .init(text: "Verified result", isError: false)
    }
}
