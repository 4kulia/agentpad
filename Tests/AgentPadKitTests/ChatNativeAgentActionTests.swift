import AppKit
import AgentPadQuietTestSupport
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// A real retained channel run with an in-process runner and fixture transcript.
/// Shared with the paired W07 captures; opening the session is always intercepted.
@MainActor final class ChatNativeRetainedRequestFixture {
    let directory: URL
    let scope = TeamServiceTestScope()
    let base: ChatChannelExecutionTests.Fixture
    let runner: F6Runner
    let run: ChatRunRecord
    let model: ChatChannelModel
    let owner: ChatChannelOwnerModel
    let requestID = "f5000000-0000-4000-8000-000000000003"
    let rootID = ChatTimelineReferenceFixture.root
    var transcriptURL: URL { runner.transcript(run.conversationId) }
    private var closed = false

    init(directory: URL? = nil) async throws {
        XCTAssertTrue(APQuietIsEnabled())
        let location = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("native-retained-request-\(UUID())")
        self.directory = location
        runner = F6Runner(projects: location.appendingPathComponent("claude-projects"))
        let base = try await ChatChannelExecutionTests.Fixture(root: location, executor: runner)
        self.base = base
        try base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        base.service.isServerKnown = { _, _ in true }
        run = try await base.finish()
        try base.write("""
            INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
            VALUES (?, ?, ?, 1, ?, 1, 1, 'A fixture channel question.', '[]', 2)
            """, [rootID, ChatTimelineReferenceFixture.channel, CallJSON.boris, ChatTimelineReferenceFixture.date])
        model = ChatChannelModel(key: base.key, channel: ChatTimelineReferenceFixture.channel)
        model.service = base.service; model.tabID = UUID(); model.confirmation = ConfirmationCoordinator()
        model.follow(base.store); model.openThread(rootID)
        owner = ChatChannelOwnerModel(service: base.service, key: base.key, channel: model.channel)
        try await settle()
        XCTAssertTrue(owner.canOpenSession(requestID))
        XCTAssertEqual(model.threadRequests.map(\.id), [requestID])
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(80)) }
    func takeTranscript() throws -> Data {
        let data = try Data(contentsOf: transcriptURL)
        try FileManager.default.removeItem(at: transcriptURL)
        return data
    }
    func restoreTranscript(_ data: Data) throws { try data.write(to: transcriptURL) }
    func close() async {
        guard !closed else { return }; closed = true
        base.sender?.hold(); await base.service.disconnect(); scope.close()
        ChatStubProtocol.reset(); try? FileManager.default.removeItem(at: directory)
        XCTAssertNil(APQuietFailure())
    }
}

@MainActor final class ChatNativeAgentActionTests: XCTestCase {
    private typealias S = NativeTimelineSnapshot
    private var fixtures: [ChatNativeActionFixture] = []
    private var retained: [ChatNativeRetainedRequestFixture] = []
    private var guardServices: [ChatService] = []
    override func tearDown() async throws {
        for service in guardServices.reversed() { await service.disconnect() }
        guardServices.removeAll()
        for fixture in retained.reversed() { await fixture.close() }
        for fixture in fixtures.reversed() { await fixture.close() }
        retained.removeAll(); fixtures.removeAll()
    }
    private func fixture(count: Int = 1) async throws -> ChatNativeActionFixture {
        let f = try await ChatNativeActionFixture(count: count); fixtures.append(f)
        try await f.settle(); return f
    }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(ChatTimelineReferenceCapture.descendants(view, NSButton.self).first {
            !$0.isHiddenOrHasHiddenAncestor && ($0.title == title || $0.accessibilityLabel() == title)
        }, "Missing live native action: " + title)
    }
    private func message(_ f: ChatNativeActionFixture, _ id: String) throws -> S.Message {
        let row = try XCTUnwrap(f.coordinator.snapshot?.rows.first { $0.messageID == id })
        guard case .message(let value) = row.payload else { throw ChatTimelineParityLayout.failure("Message missing") }
        return value
    }
    private func rebind(_ cell: ChatNativeShellCell, index: Int, coordinator: NativeChatTimelineCoordinator,
                        actions: ChatTimelineActions?) throws {
        let snapshot = try XCTUnwrap(coordinator.snapshot), row = snapshot.rows[index]
        let plan = try XCTUnwrap(coordinator.layoutPlan(at: index))
        cell.configure(row: row, epoch: snapshot.presentationEpoch, plan: plan,
            content: coordinator.layoutEngine.content(row, snapshot: snapshot, width: plan.width), actions: actions)
        cell.configureActions(row: row, snapshot: snapshot, actions: actions,
            layer: try XCTUnwrap(coordinator.tableView.documentLayer))
        cell.setMediaVisible(true); cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.binding?.id, row.id)
    }

    private func applyChannelsWithoutAgentsSnapshot(_ f: ChatNativeActionFixture) throws {
        try applyChannelsWithoutAgentsSnapshot(base: f.base, model: f.model)
    }

    private func applyChannelsWithoutAgentsSnapshot(base: ChatChannelExecutionTests.Fixture, model: ChatChannelModel) throws {
        let view = try base.store.queue.read(ChatOrgView.read)
        let cards = try base.store.channels(), stamp = try base.store.channelStamp()
        let streams = try base.store.queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT stream, seq FROM cursors").map {
                ($0["stream"] as String, $0["seq"] as Int)
            })
        }
        XCTAssertTrue(view.teams.allSatisfy { !$0.archived }) // These existing fixtures have unarchived teams.
        // Actual org-state wire compatibility: channels remain present;
        // agent_channels and requests are absent, not fabricated SQL flags.
        let payload: [String: Any] = [
            "org": ["org_id": base.key.orgId, "name": view.orgName ?? "Fixture organization"],
            "members": view.members.map { ["account_id": $0.accountId, "handle": $0.handle, "name": $0.name, "role": $0.role] },
            "teams": view.teams.map { ["team_id": $0.teamId, "name": $0.name, "is_general": $0.isGeneral,
                "archived_at": NSNull(), "members": $0.members] as [String: Any] },
            "my_teams": view.teams.filter(\.mine).map(\.teamId), "admin": NSNull(),
            "channels": try JSONSerialization.jsonObject(with: JSONEncoder().encode(cards)),
            "channels_next": NSNull(), "streams": streams
        ]
        let wire = try JSONDecoder().decode(ChatOrgState.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(wire.agentChannels); XCTAssertNotNil(wire.channels)
        let session = try XCTUnwrap(base.service.orgSessions[base.key])
        session.snapshotOwed = true
        try base.store.apply(wire.snapshot, following: Set(wire.streams.keys),
            confirmsRights: try XCTUnwrap(base.service.connection).sessionId)
        try base.store.endChannelsRead(since: stamp, seen: Set(cards.map(\.channelId)))
        // The existing sync callback pays the snapshot only after these writes.
        session.snapshotOwed = false
        base.service.orgCurrent.refresh(base.service)
        XCTAssertTrue(ChatNotifications.allowed(base.service, base.key, channel: model.channel))
        XCTAssertFalse(base.service.channelAgentAllowed(base.key, channel: model.channel))
        let org = try XCTUnwrap(base.service.orgCurrent.model)
        org.set(try base.store.queue.read(ChatOrgView.read))
        guard case .ready(let card, _, _) = ChannelTabState.of(ChannelRef(base.key, channel: model.channel), model: org)
        else { return XCTFail("The normal channels-only snapshot must leave this channel readable") }
        XCTAssertEqual(card.channelId, model.channel)
    }

    func testRetainedRequestControlsMatchLegacyAfterChannelsOnlySnapshot() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced) }
        // Source-less F5 request from the real finish/journal fixture. Use the
        // normal channel-session owner/model instead of injecting a synthetic
        // owner visibility state. Separate fixtures keep route effects isolated.
        for native in [false, true] {
            let f = try await ChatNativeRetainedRequestFixture(); retained.append(f)
            f.base.service.orgCurrent.refresh(f.base.service)
            let org = try XCTUnwrap(f.base.service.orgCurrent.model)
            org.set(try await f.base.store.queue.read(ChatOrgView.read))
            let ref = ChannelRef(f.base.key, channel: f.model.channel)
            let conversation = ChatChannelSession()
            conversation.tabID = UUID()
            let ready = ChannelTabState.of(ref, model: org)
            guard case .ready = ready else { return XCTFail("Fixture channel must start readable") }
            conversation.update(ready, key: f.base.key, store: f.base.store, service: f.base.service)
            let model = try XCTUnwrap(conversation.model), owner = try XCTUnwrap(conversation.ownerModel)
            model.openThread(f.rootID)
            try await f.settle()
            XCTAssertEqual(model.threadRequests.map(\.id), [f.requestID])
            XCTAssertFalse(model.sourceStatuses.contains { $0.id == f.requestID })
            XCTAssertTrue(owner.visible); XCTAssertTrue(owner.canOpenSession(f.requestID))
            let members = try await f.base.store.queue.read(ChatOrgView.read).members
            let card = try XCTUnwrap(model.threadRequests.first)
            func legacyCard(_ value: ChatChannelRequests.Card) -> AnyView {
                AnyView(ChatRequestCardRow(card: value, members: members, ownerModel: owner)
                    .padding(18).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                    .environment(\.colorScheme, .light))
            }
            let legacyView = NSHostingView(rootView: legacyCard(card))
            let legacy = ChatQuietHost(view: legacyView, dark: false)
            let adapter = ChatTimelineAdapter(), coordinator = NativeChatTimelineCoordinator()
            let view = NativeChatTimelineContainer(coordinator: coordinator)
            let host = ChatQuietHost(view: view, dark: false, width: 760, height: 600)
            defer { coordinator.dispose(); adapter.invalidate(); host.close(); legacy.close() }
            func update() -> S {
                let snapshot = adapter.snapshot(model: model, root: f.rootID, members: members, mentionable: [], me: f.base.key.accountId,
                    archived: false, ownerModel: owner, style: ChatTimelineAdapter.style(scale: 2, locale: .current,
                        calendar: .current, increasedContrast: false, alwaysShowTime: false))
                coordinator.actions = adapter.actions; view.update(snapshot); return snapshot
            }
            func requestCell(_ snapshot: S) throws -> ChatNativeShellCell {
                let index = try XCTUnwrap(snapshot.rows.firstIndex {
                    if case .legacyRequest(let value) = $0.payload { return value.id == f.requestID }; return false
                })
                return try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChatNativeShellCell)
            }
            let initial = update(); try await host.settle()
            APQuietSelectWindow(legacy.window); try await legacy.settle()
            _ = try button("Open Session", in: requestCell(initial).request)
            _ = try legacy.control("Open Session")
            let commands = try f.base.commands(), transcript = try Data(contentsOf: f.transcriptURL)
            let marks = try await f.base.store.queue.read {
                try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
            }

            // Derive checking from the real session flag; the actual channel
            // session retains owner/model while the normal snapshot is pending.
            f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
            let checking = ChannelTabState.of(ref, model: org)
            XCTAssertEqual(checking, .checking)
            conversation.update(checking, key: f.base.key, store: f.base.store, service: f.base.service)
            XCTAssertTrue(conversation.model === model); XCTAssertTrue(conversation.ownerModel === owner)
            try applyChannelsWithoutAgentsSnapshot(base: f.base, model: model)
            let afterState = ChannelTabState.of(ref, model: f.base.service.orgCurrent.model)
            guard case .ready = afterState else { return XCTFail("Retained channel must become ready again") }
            conversation.update(afterState, key: f.base.key, store: f.base.store, service: f.base.service)
            try await f.settle()
            XCTAssertTrue(conversation.model === model); XCTAssertTrue(conversation.ownerModel === owner)
            XCTAssertEqual(model.threadRoot, f.rootID)
            var currentCard = card
            currentCard.agentName = "an agent" // The existing query falls back after membership is cleared.
            XCTAssertEqual(model.threadRequests, [currentCard])
            legacyView.rootView = legacyCard(try XCTUnwrap(model.threadRequests.first))
            XCTAssertFalse(model.sourceStatuses.contains { $0.id == f.requestID })
            XCTAssertTrue(ChatNotifications.allowed(f.base.service, f.base.key, channel: model.channel))
            XCTAssertFalse(owner.visible); XCTAssertFalse(owner.canOpenSession(f.requestID))

            let settled = update(); try await host.settle()
            APQuietSelectWindow(legacy.window); try await legacy.settle()
            let cell = try requestCell(settled)
            _ = try legacy.control("Open Request…")
            let openRequest = try button("Open Request…", in: cell.request)
            XCTAssertFalse(legacy.strings.contains("Open Session"))
            XCTAssertFalse(ChatTimelineReferenceCapture.descendants(cell.request, NSButton.self).contains {
                !$0.isHiddenOrHasHiddenAncestor && $0.title == "Open Session"
            })
            let current = try XCTUnwrap(settled.rows.compactMap { row -> S.Request? in
                if case .legacyRequest(let value) = row.payload { return value }; return nil
            }.first)
            XCTAssertTrue(current.canOpenRequest); XCTAssertFalse(current.canOpenSession)
            XCTAssertNil(current.problem)

            // Initialize the shared startup gate before temporarily replacing
            // router.admit; its lazy initializer otherwise installs that gate.
            _ = SupportTabs.shared.navigation
            let router = TabRouter.shared
            let oldAdmit = router.admit, oldStores = router.stores, oldHost = router.ensureHost
            let oldReveal = router.revealWindow, oldChat = RequestTabs.shared.chat, oldTeam = RequestTabs.shared.team
            let oldOpen = TeamUI.openTab
            var terminalOpens: [[String]] = []
            TeamUI.openTab = { terminalOpens.append([$0, $1, $2]) }
            let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
                engineFactory: { XCTFail("Retained request details must not launch a terminal"); return TestEngine() }, optionsProvider: { _ in nil })
            router.admit = nil; router.stores = { [workspace] }; router.ensureHost = { workspace }; router.revealWindow = { _ in }
            RequestTabs.shared.chat = f.base.service; RequestTabs.shared.team = f.base.teamService
            defer {
                workspace.terminate(); router.admit = oldAdmit; router.stores = oldStores; router.ensureHost = oldHost
                router.revealWindow = oldReveal; RequestTabs.shared.chat = oldChat; RequestTabs.shared.team = oldTeam
                TeamUI.openTab = oldOpen
            }
            if native {
                APQuietSelectWindow(host.window)
                openRequest.performClick(nil)
            } else {
                APQuietSelectWindow(legacy.window); try legacy.press("Open Request…")
            }
            let route = ToolRoute.request(.server(OrgKey(f.base.key)), requestID: f.requestID)
            let routes = (workspace.allSessions + workspace.popups.sessions).compactMap { $0.tabState?.route }
            XCTAssertTrue(routes.contains(route), native ? "native" : "legacy")
            XCTAssertEqual(terminalOpens, [])
            XCTAssertEqual(try f.base.commands(), commands)
            XCTAssertEqual(try Data(contentsOf: f.transcriptURL), transcript)
            let afterMarks = try await f.base.store.queue.read {
                try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
            }
            XCTAssertEqual(afterMarks, marks)
        }
    }

    func testSourceActionsMatchMountedLegacyAfterChannelsOnlySnapshot() async throws {
        _ = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced) }
        // Independent real fixture for each renderer avoids resetting command
        // or intent side effects merely to make the second invocation comparable.
        for native in [false, true] {
            for scenario in ["stop", "server-cancel", "answer", "details", "local-cancel"] {
                let f = try await fixture(count: 2)
                f.base.service.isServerKnown = { _, _ in true }
                let source: String
                let answer = f.messages[1].id
                let request: String
                let title: String
                if scenario == "local-cancel" {
                    try f.base.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
                    try await f.base.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
                    f.base.calls.sessionFilesRoot = f.base.service.claudeProjectsRoot
                    f.base.service.serverCapabilities[f.base.key.server] = ["chat.channel_ux1", "chat.session_tools"]
                    let text = "@billing@anna Keep this local question."
                    f.model.saveDraft(text, root: nil)
                    source = try f.base.service.sendChannel(f.base.key, channel: f.model.channel, root: nil, text: text,
                        mentions: [], agents: [XCTUnwrap(f.base.store.channelAgents(f.model.channel).first)],
                        draftVersion: XCTUnwrap(f.model.draftVersion(root: nil)), mentionOnly: false)
                    request = try await f.base.store.queue.read { try XCTUnwrap(String.fetchOne($0,
                        sql: "SELECT request_id FROM channel_call_intents WHERE message_id = ?", arguments: [source])) }
                    title = "Cancel request"
                } else {
                    source = f.messages[0].id
                    request = UUID().uuidString.lowercased()
                    let state = scenario == "answer" ? "finished" : scenario == "server-cancel" ? "submitted" : "running"
                    let run = UUID().uuidString.lowercased()
                    try f.base.move(state, 1, id: request, run: run, publication: scenario == "answer" ? "published" : nil)
                    try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ? WHERE request_id = ?",
                        [source, f.base.key.accountId, f.base.key.accountId, request])
                    if scenario == "answer" {
                        try f.base.write("UPDATE messages SET run_id = ?, thread_root_id = ?, author_agent_id = ? WHERE message_id = ?",
                            [run, source, CallJSON.agent, answer])
                    }
                    title = scenario == "stop" ? "Stop agent" : scenario == "server-cancel" ? "Cancel request"
                        : scenario == "answer" ? "Go to answer" : "Request details"
                }
                try await f.settle()
                let legacy = ChatQuietHost(content: AnyView(ChatSourceProgress(model: f.model, source: source)
                    .padding(20).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)), dark: false)
                defer { legacy.close() }
                try await legacy.settle()
                _ = try legacy.control(title)
                _ = try button(title, in: f.row(source).sources)
                let before = try f.base.commands()
                let sourceMessage = try XCTUnwrap(f.model.message(source))
                let readMarks = try await f.base.store.queue.read {
                    try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
                }
                try applyChannelsWithoutAgentsSnapshot(f)
                try await f.settle(); try await legacy.settle()
                XCTAssertEqual(f.model.message(source), sourceMessage)
                XCTAssertEqual(f.model.sourceStatuses.map(\.id), [request])
                _ = try legacy.control(title)
                let control = try button(title, in: f.row(source).sources)

                // Details uses the actual RequestTabs gateway in an isolated
                // workspace. No terminal engine, window reveal, or live service.
                let router = TabRouter.shared
                let oldAdmit = router.admit, oldStores = router.stores, oldHost = router.ensureHost
                let oldReveal = router.revealWindow, oldChat = RequestTabs.shared.chat, oldTeam = RequestTabs.shared.team
                let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
                    engineFactory: { XCTFail("Source details must not launch a terminal"); return TestEngine() }, optionsProvider: { _ in nil })
                router.admit = nil; router.stores = { [workspace] }; router.ensureHost = { workspace }; router.revealWindow = { _ in }
                RequestTabs.shared.chat = f.base.service; RequestTabs.shared.team = f.base.teamService
                defer {
                    workspace.terminate(); router.admit = oldAdmit; router.stores = oldStores; router.ensureHost = oldHost
                    router.revealWindow = oldReveal; RequestTabs.shared.chat = oldChat; RequestTabs.shared.team = oldTeam
                }
                if native { APQuietSelectWindow(f.host.window); control.performClick(nil) }
                else { APQuietSelectWindow(legacy.window); try legacy.press(title) }
                let after = try f.base.commands()
                let prefix = "\(native ? "native" : "legacy") \(scenario)"
                switch scenario {
                case "stop":
                    let prior = Set(before.map(\.commandId)), added = after.filter { !prior.contains($0.commandId) }
                    XCTAssertEqual(after.filter { prior.contains($0.commandId) }, before, prefix)
                    XCTAssertEqual(added.count, 1, prefix)
                    if let command = added.first {
                        XCTAssertEqual(command.type, "request.stop", prefix)
                        XCTAssertEqual(ChatService.args(command), ["request_id": .string(request)], prefix)
                    }
                case "server-cancel":
                    XCTAssertEqual(after, before, prefix)
                    let expected = "The channel request is not available."
                    if native {
                        XCTAssertEqual(f.adapter.actions?.sourcePresentation(messageID: source), .init(expanded: false, problem: expected), prefix)
                    } else {
                        try await legacy.settle(); XCTAssertTrue(legacy.strings.contains(expected), prefix)
                    }
                case "local-cancel":
                    let call = try XCTUnwrap(before.first { $0.type == "request.create_in_channel_v2" })
                    var expected = call; expected.state = .dropped; expected.error = "cancelled"
                    XCTAssertEqual(after.first { $0.commandId == call.commandId }, expected, prefix)
                    XCTAssertEqual(after.filter { $0.commandId != call.commandId }, before.filter { $0.commandId != call.commandId }, prefix)
                    XCTAssertFalse(after.contains { $0.type == "request.cancel" }, prefix)
                    XCTAssertNil(try f.base.journal.channelAuthority(request), prefix)
                    let cancelled = try await f.base.store.queue.read { try Int.fetchOne($0,
                        sql: "SELECT cancelled FROM channel_call_intents WHERE request_id = ?", arguments: [request]) }
                    XCTAssertEqual(cancelled, 1, prefix)
                    try await f.settle()
                    XCTAssertEqual(f.model.sourceStatuses, [], prefix)
                    XCTAssertEqual(f.model.message(source), sourceMessage, prefix)
                case "answer":
                    XCTAssertEqual(f.model.revealMessageID, answer, prefix)
                    XCTAssertEqual(f.model.threadRoot, source, prefix)
                    XCTAssertTrue(f.model.hasNavigationReturn, prefix)
                    XCTAssertEqual(after, before, prefix)
                default:
                    let route = ToolRoute.request(.server(OrgKey(f.base.key)), requestID: request)
                    let routes = (workspace.allSessions + workspace.popups.sessions).compactMap { $0.tabState?.route }
                    XCTAssertTrue(routes.contains(route), prefix)
                    XCTAssertEqual(after, before, prefix)
                }
                let afterMarks = try await f.base.store.queue.read {
                    try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
                }
                XCTAssertEqual(afterMarks, readMarks, prefix)
            }
        }
    }

    func testSourceAnswerUsesCurrentNativeControlAfterReuseWithoutChangingReadMarks() async throws {
        let f = try await fixture(count: 4)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        f.base.service.isServerKnown = { _, _ in true }
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        for index in 0..<2 {
            let run = UUID().uuidString.lowercased()
            try f.base.move("finished", 1, id: ids[index], run: run, publication: "published")
            try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ? WHERE request_id = ?",
                [f.messages[index].id, f.base.key.accountId, CallJSON.boris, ids[index]])
            try f.base.write("UPDATE messages SET run_id = ?, thread_root_id = ?, author_agent_id = ? WHERE message_id = ?",
                [run, f.messages[index].id, CallJSON.agent, f.messages[index + 2].id])
        }
        try f.base.write("INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq, muted) VALUES (?, 1, 1)", [f.model.channel])
        try await f.settle()
        for index in 0..<2 {
            XCTAssertEqual(try message(f, f.messages[index].id).content.sources, [.init(value: .init(
                id: ids[index], source: f.messages[index].id, agent: "billing", state: "finished",
                initiator: CallJSON.boris, owner: f.base.key.accountId, publication: "published", error: nil,
                answer: f.messages[index + 2].id), word: "answered", activity: nil, connected: true, canGoToAnswer: true)])
        }
        let commands = try f.base.commands()
        let readMarks = try await f.base.store.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description) }
        let cell = try f.row(f.messages[0].id), oldButton = try button("Go to answer", in: cell.sources)
        try rebind(cell, index: XCTUnwrap(f.coordinator.messageIndex(f.messages[1].id)), coordinator: f.coordinator, actions: f.adapter.actions)
        oldButton.performClick(nil)
        XCTAssertNil(f.model.revealMessageID)
        try button("Go to answer", in: cell.sources).performClick(nil)
        XCTAssertEqual(f.model.revealMessageID, f.messages[3].id)
        XCTAssertEqual(f.model.threadRoot, f.messages[1].id)
        XCTAssertTrue(f.model.hasNavigationReturn)
        XCTAssertEqual(try f.base.commands(), commands)
        let after = try await f.base.store.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description) }
        XCTAssertEqual(after, readMarks)
    }

    func testStaleSourceStopReturnsRealServiceErrorAndDoesNotEnqueue() async throws {
        let f = try await fixture()
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        let id = UUID().uuidString.lowercased(), source = f.messages[0].id
        try f.base.move("running", 1, id: id)
        try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ? WHERE request_id = ?", [source, f.base.key.accountId, id])
        try await f.settle()
        let cell = try f.row(source), stop = try button("Stop agent", in: cell.sources)
        let before = try f.base.commands(), original = f.model.sourceStatuses
        // The mounted button holds the previous visible state; the gateway
        // must query the current request before admitting a command.
        try f.base.write("UPDATE requests SET state = 'approved', version = 2 WHERE request_id = ?", [id])
        XCTAssertEqual(f.model.sourceStatuses, original)
        stop.performClick(nil)
        XCTAssertEqual(f.adapter.actions?.sourcePresentation(messageID: source),
            .init(expanded: false, problem: "Only a call that is running can be stopped."))
        XCTAssertEqual(try f.base.commands(), before)
        try await f.settle()
        XCTAssertEqual(try message(f, source).content.sourceProblem, "Only a call that is running can be stopped.")
        XCTAssertEqual(try message(f, source).content.sources.map(\.value.state), ["approved"])
    }

    func testReusedRequestControlsUseActualRetainedSessionGatewayAndFilteredCurrentTail() async throws {
        let f = try await ChatNativeRetainedRequestFixture(); retained.append(f)
        AgentPadFonts.registerOnce(); ChatScrollAppKitSettings.install(); _ = NSApplication.shared
        let other = UUID().uuidString.lowercased()
        try f.base.move("submitted", 1, id: other)
        try await f.settle()
        let adapter = ChatTimelineAdapter(), coordinator = NativeChatTimelineCoordinator()
        let view = NativeChatTimelineContainer(coordinator: coordinator)
        let host = ChatQuietHost(view: view, dark: false, width: 760, height: 600)
        defer { coordinator.dispose(); adapter.invalidate(); host.close() }
        let members: [ChatOrgView.Member] = [.init(accountId: f.base.key.accountId, handle: "anna", name: "Anna", role: "owner"),
            .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")]
        func update() -> S {
            let snapshot = adapter.snapshot(model: f.model, root: f.rootID, members: members, mentionable: [], me: f.base.key.accountId,
                archived: false, ownerModel: f.owner, style: ChatTimelineAdapter.style(scale: 2, locale: .current,
                    calendar: .current, increasedContrast: false, alwaysShowTime: false))
            coordinator.actions = adapter.actions; view.update(snapshot); return snapshot
        }
        func index(_ id: String, in snapshot: S) throws -> Int {
            try XCTUnwrap(snapshot.rows.firstIndex { if case .legacyRequest(let value) = $0.payload { return value.id == id }; return false })
        }
        func request(_ id: String, in snapshot: S) throws -> S.Request {
            guard case .legacyRequest(let value) = snapshot.rows[try index(id, in: snapshot)].payload else {
                throw ChatTimelineParityLayout.failure("Request missing")
            }
            return value
        }
        let snapshot = update(); try await host.settle()
        let oldIndex = try index(other, in: snapshot), currentIndex = try index(f.requestID, in: snapshot)
        let cell = try XCTUnwrap(coordinator.tableView.view(atColumn: 0, row: oldIndex, makeIfNecessary: true) as? ChatNativeShellCell)
        try rebind(cell, index: currentIndex, coordinator: coordinator, actions: adapter.actions)
        var opened: [String] = [], sessions: [[String]] = []
        adapter.actions?.requestDetails = { id, key in XCTAssertEqual(key, f.base.key); opened.append(id) }
        let previousOpen = TeamUI.openTab
        TeamUI.openTab = { folder, command, title in sessions.append([folder, command, title]) }
        defer { TeamUI.openTab = previousOpen }
        let commands = try f.base.commands(), transcript = try Data(contentsOf: f.transcriptURL)
        let expectedSession = [f.base.agent.folder, "claude --resume \(f.run.conversationId) --fork-session", "Channel · your copy"]
        let openRequest = try button("Open Request…", in: cell.request), openSession = try button("Open Session", in: cell.request)
        openRequest.performClick(nil); openSession.performClick(nil)
        XCTAssertEqual(opened, [f.requestID]); XCTAssertEqual(sessions, [expectedSession])
        XCTAssertEqual(try f.base.commands(), commands); XCTAssertEqual(try Data(contentsOf: f.transcriptURL), transcript)
        let available = try request(f.requestID, in: snapshot)
        XCTAssertEqual(available, .init(id: f.requestID, agentName: "billing", initiatorAccountID: CallJSON.boris,
            ownerAccountID: f.base.key.accountId, state: "finished", publication: "awaiting_publish", publishReason: nil,
            cause: nil, title: "Boris asked billing (Anna's agent)", stateWord: "done · waiting for the owner to publish the answer",
            help: TeamRequestState.finished.meaning ?? "finished", canOpenRequest: true, canOpenSession: true))

        let saved = try f.takeTranscript()
        XCTAssertFalse(f.owner.canOpenSession(f.requestID))
        openSession.performClick(nil)
        try f.restoreTranscript(saved)
        let rejection = "This conversation is not available through the channel on this Mac."
        var expected = available; expected.problem = rejection
        XCTAssertEqual(try request(f.requestID, in: update()), expected)
        XCTAssertEqual(sessions, [expectedSession]); XCTAssertEqual(try f.base.commands(), commands)
        try rebind(cell, index: currentIndex, coordinator: coordinator, actions: adapter.actions)
        XCTAssertEqual(cell.request.parityTexts.first { $0.id.hasSuffix("/problem") }?.text.string, rejection)

        _ = try f.takeTranscript()
        let closed = try request(f.requestID, in: update())
        XCTAssertFalse(closed.canOpenSession)
        try rebind(cell, index: currentIndex, coordinator: coordinator, actions: adapter.actions)
        XCTAssertFalse(cell.request.parityTexts.contains { $0.id.hasSuffix("/problem") || $0.id.hasSuffix("/Open Session") })
        openSession.performClick(nil)
        XCTAssertEqual(sessions, [expectedSession])
        try f.restoreTranscript(saved)

        try f.base.write("UPDATE requests SET source_message_id = ? WHERE request_id = ?", [f.rootID, f.requestID])
        try await f.settle()
        // The rendered old card is still present here. Its click must query
        // current filtered eligibility before the table applies a new snapshot.
        openRequest.performClick(nil); openSession.performClick(nil)
        XCTAssertEqual(opened, [f.requestID]); XCTAssertEqual(sessions, [expectedSession])
        let filtered = update()
        XCTAssertEqual(filtered.rows.compactMap { if case .legacyRequest(let value) = $0.payload { return value.id }; return nil }, [other])
        try rebind(cell, index: index(other, in: filtered), coordinator: coordinator, actions: adapter.actions)
        try button("Open Request…", in: cell.request).performClick(nil)
        XCTAssertEqual(opened, [f.requestID, other]); XCTAssertEqual(sessions, [expectedSession])
        XCTAssertEqual(try f.base.commands(), commands)
    }

    func testMembershipAddUsesReboundAgentAndExistingConsentBeforeEnqueue() async throws {
        let f = try await fixture(count: 2)
        let agentIDs = [CallJSON.agent, UUID().uuidString.lowercased()]
        try f.base.write("DELETE FROM agent_channels")
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        for (index, name) in ["first", "second"].enumerated() {
            try f.base.write("""
                INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available)
                VALUES (?, ?, ?, '', 'read', 1, 1)
                """, [agentIDs[index], f.base.key.accountId, name])
            try f.base.write("UPDATE messages SET text = ? WHERE message_id = ?",
                ["@\(name)@anna Please check this question.", f.messages[index].id])
        }
        let previousTeam = TeamService.sharedForTesting, previousHost = TabRouter.shared.ensureHost
        let previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
            engineFactory: { XCTFail("Membership routing must not launch a terminal"); return TestEngine() }, optionsProvider: { _ in nil })
        TabRouter.shared.ensureHost = { workspace }
        defer {
            workspace.terminate(); TabRouter.shared.ensureHost = previousHost
            TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.sharedForTesting = previousOrg
        }
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        f.update()
        for (index, name) in ["first", "second"].enumerated() {
            XCTAssertEqual(try message(f, f.messages[index].id).content.membershipHints,
                [.init(agentID: agentIDs[index], address: "\(name)@anna", canAdd: true, guidance: "Add it to request an answer.")])
        }
        let commands = try f.base.commands(), cell = try f.row(f.messages[0].id)
        let stale = try button("Add @first@anna to channel", in: cell.membership)
        try rebind(cell, index: XCTUnwrap(f.coordinator.messageIndex(f.messages[1].id)), coordinator: f.coordinator, actions: f.adapter.actions)
        stale.performClick(nil)
        XCTAssertNil(workspace.popups.visibleConversation)
        try button("Add @second@anna to channel", in: cell.membership).performClick(nil)
        let session = try XCTUnwrap(workspace.popups.visibleConversation)
        let conversation = try XCTUnwrap(session.channelConversation), consent = conversation.confirmation
        XCTAssertEqual(session.channel, ChannelRef(f.base.key, channel: f.model.channel))
        XCTAssertTrue(conversation.showingAgents)
        XCTAssertEqual(consent.context?.targetID, "agent:" + agentIDs[1])
        XCTAssertEqual(consent.context?.scope, OrgKey(f.base.key))
        XCTAssertEqual(consent.title, "Add second to #billing?")
        XCTAssertEqual(consent.phase, .awaiting)
        XCTAssertEqual(try f.base.commands(), commands, "Opening membership consent cannot itself add or ask an agent")
        consent.canShow = { true }; consent.shown(true); consent.confirm()
        for _ in 0..<100 {
            if consent.phase != .executing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(consent.phase, .completed)
        let added = try f.base.commands().filter { $0.type == "agent.add_to_channel" }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(added.first)),
            ["agent_id": .string(agentIDs[1]), "channel_id": .string(f.model.channel)])
        XCTAssertFalse(try f.base.commands().contains { $0.type.hasPrefix("request.create") })
        let admitted = try f.base.commands()
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        try button("Add @second@anna to channel", in: cell.membership).performClick(nil)
        XCTAssertFalse(try XCTUnwrap(f.adapter.actions).addAgent(messageID: f.messages[1].id, agentID: agentIDs[1]))
        XCTAssertEqual(try f.base.commands(), admitted)
    }

    func testLocalPendingCancelRetiresExistingIntentAndRechecksCapabilityAndRights() async throws {
        let f = try await fixture()
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        try f.base.write("UPDATE agent_channels SET executor_session_id = 's-anna'")
        try await f.base.journal.queue.write { try $0.execute(sql: "UPDATE assignments SET published_session = 's-anna'") }
        f.base.calls.sessionFilesRoot = f.base.service.claudeProjectsRoot
        f.base.service.serverCapabilities[f.base.key.server] = ["chat.channel_ux1", "chat.session_tools"]
        f.base.service.isServerKnown = { _, _ in true }
        let text = "@billing@anna Why was this retried?"
        f.model.saveDraft(text, root: nil)
        let source = try f.base.service.sendChannel(f.base.key, channel: f.model.channel, root: nil, text: text, mentions: [],
            agents: [XCTUnwrap(f.base.store.channelAgents(f.model.channel).first)],
            draftVersion: XCTUnwrap(f.model.draftVersion(root: nil)), mentionOnly: false)
        let request = try await f.base.store.queue.read { try XCTUnwrap(String.fetchOne($0,
            sql: "SELECT request_id FROM channel_call_intents WHERE message_id = ?", arguments: [source])) }
        try await f.settle()
        XCTAssertEqual(try message(f, source).content.sources, [.init(value: .init(id: request, source: source,
            agent: "billing", state: "pending", initiator: nil, owner: nil, publication: nil, error: nil, local: true),
            word: "queued", activity: nil, connected: true, canGoToAnswer: false)])
        let actions = try XCTUnwrap(f.adapter.actions), cell = try f.row(source)
        let cancel = try button("Cancel request", in: cell.sources), before = try f.base.commands()
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        cancel.performClick(nil)
        XCTAssertFalse(actions.performSource(.cancel, messageID: source, requestID: request))
        XCTAssertEqual(try f.base.commands(), before)
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = false
        try applyChannelsWithoutAgentsSnapshot(f)
        cancel.performClick(nil)
        let after = try f.base.commands()
        let call = try XCTUnwrap(before.first { $0.type == "request.create_in_channel_v2" })
        var expected = call; expected.state = .dropped; expected.error = "cancelled"
        XCTAssertEqual(after.first { $0.commandId == call.commandId }, expected)
        XCTAssertEqual(after.filter { $0.commandId != call.commandId }, before.filter { $0.commandId != call.commandId })
        XCTAssertFalse(after.contains { $0.type == "request.cancel" })
        XCTAssertNil(try f.base.journal.channelAuthority(request))
        let cancelled = try await f.base.store.queue.read { try Int.fetchOne($0,
            sql: "SELECT cancelled FROM channel_call_intents WHERE request_id = ?", arguments: [request]) }
        XCTAssertEqual(cancelled, 1)
        try await f.settle()
        XCTAssertEqual(try message(f, source).content.sources, [])
        XCTAssertEqual(f.model.message(source)?.text, text)
    }

    func testAskAndPublicationStayOwnedOutsideTheNativeRowBoundary() async throws {
        let f = try await ChatNativeRetainedRequestFixture(); retained.append(f)
        let adapter = ChatTimelineAdapter()
        defer { adapter.invalidate() }
        let style = ChatTimelineAdapter.style(scale: 2, locale: .current, calendar: .current,
            increasedContrast: false, alwaysShowTime: false)
        func snapshot() -> S {
            adapter.snapshot(model: f.model, root: f.rootID, members: [], mentionable: [], me: f.base.key.accountId,
                archived: false, ownerModel: f.owner, style: style)
        }
        let before = snapshot(), requests = f.owner.requests, preview = f.owner.publicationText(f.requestID)
        XCTAssertNotNil(preview)
        let offer = ChatChannelAsk.Offer(messageId: f.rootID, agentId: CallJSON.agent, address: "billing@anna",
            text: "A follow-up kept outside the timeline.", root: f.rootID)
        f.model.beginAsk(offer)
        let ask = try XCTUnwrap(f.model.channelAsk)
        var expected = ChannelAskDraft(offer: offer, text: offer.text, chosen: [f.rootID])
        expected.requestID = ask.fields.requestID
        XCTAssertEqual(ask.fields, expected)
        XCTAssertEqual(snapshot().rows.map(\.payload), before.rows.map(\.payload))
        let command = try f.base.service.publishChannelResult(f.base.key, requestId: f.requestID, publish: true)
        for state in ["pending", "failed", "unconfirmed"] {
            try f.base.write("UPDATE outbox SET state = ?, error = ? WHERE command_id = ?",
                [state, state == "failed" ? "too_large" : nil, command.commandId])
            try await f.settle()
            XCTAssertNotNil(f.base.service.channelPublicationIssue(f.base.key, requestId: f.requestID))
            XCTAssertEqual(snapshot().rows.map(\.payload), before.rows.map(\.payload))
            XCTAssertTrue(f.model.channelAsk === ask)
            XCTAssertEqual(ask.fields, expected)
            XCTAssertEqual(try ChatCompositionDrafts.read(ChannelAskDraft.self, id: "channel-ask:" + f.model.channel, store: f.base.store), expected)
            XCTAssertEqual(f.owner.requests, requests)
            XCTAssertEqual(f.owner.publicationText(f.requestID), preview)
        }
    }

    /// Opens only a fake-token service and existing SQLite fixture schema. It does
    /// not call start(), use live transport, or launch an executor.
    private func guardService(directory: URL, key: ChatOrgKey, channel: String) throws -> ChatService {
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        service.followsFeed = false
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        service.closeRemoteSession = { _, _ in }
        guardServices.append(service)
        try seedGuardOrganization(service: service, key: key, channel: channel, sessionID: "w07-guard-session")
        return service
    }

    /// Also supports a current-organization switch on an existing fixture service.
    /// Matching IDs in distinct organizations are intentional: the scope gate,
    /// rather than an unrelated missing row, must reject the stale action.
    private func seedGuardOrganization(service: ChatService, key: ChatOrgKey, channel: String,
                                       sessionID: String) throws {
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId,
            sessionId: sessionID, deviceName: "Fixture Mac", orgId: key.orgId), token: "test-only")
        let session = service.session(for: key), store = try XCTUnwrap(session.store)
        try store.finishGeneration("g1")
        try service.journal?.finish(key, "g1")
        let teamID = UUID().uuidString.lowercased()
        try store.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: key.accountId, handle: "anna", name: "Anna", role: "owner"),
            .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
            teams: [.init(teamId: teamID, name: "Billing", mine: true)],
            teamMembers: [.init(teamId: teamID, accountId: key.accountId)],
            channels: [.init(channelId: channel, teamId: teamID, name: "billing", archived: false, version: 1)],
            channelsComplete: true, agentChannels: []), confirmsRights: sessionID)
        try store.endChannelsRead(since: 0, seen: [channel])
        try store.queue.write { db in
            try db.execute(sql: "UPDATE meta SET agents_served = 1 WHERE id = 1")
            try db.execute(sql: """
                INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available)
                VALUES (?, ?, 'first', '', 'read', 1, 1)
                """, arguments: [CallJSON.agent, key.accountId])
        }
        session.snapshotOwed = false
    }

    func testSourceAuthorityRejectsTerminalForeignAndWithdrawnAnswerFromMountedControls() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        f.base.service.isServerKnown = { _, _ in true }
        let id = UUID().uuidString.lowercased(), source = f.messages[0].id
        try f.base.move("submitted", 1, id: id)
        try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ? WHERE request_id = ?",
            [source, f.base.key.accountId, f.base.key.accountId, id])
        try f.base.write("INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq, muted) VALUES (?, 1, 1)", [f.model.channel])
        try await f.settle()
        let actions = try XCTUnwrap(f.adapter.actions), cancel = try button("Cancel request", in: f.row(source).sources)
        let before = try f.base.commands()
        let marks = try await f.base.store.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description) }
        for (state, initiator, version) in [("cancelled", f.base.key.accountId, 2), ("submitted", CallJSON.boris, 3)] {
            try f.base.write("UPDATE requests SET state = ?, initiator_account_id = ?, version = ? WHERE request_id = ?",
                [state, initiator, version, id])
            // Refresh the real model, retaining the actual rendered old control.
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(f.model.sourceStatuses, [.init(id: id, source: source, agent: "billing", state: state,
                initiator: initiator, owner: f.base.key.accountId, publication: nil, error: nil)])
            cancel.performClick(nil)
            XCTAssertFalse(actions.performSource(.cancel, messageID: source, requestID: id), state)
            XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
            XCTAssertEqual(try f.base.commands(), before)
        }
        let run = UUID().uuidString.lowercased(), answer = f.messages[1].id
        try f.base.write("UPDATE requests SET state = 'finished', publication = 'published', run_id = ?, version = 4 WHERE request_id = ?", [run, id])
        try f.base.write("UPDATE messages SET run_id = ?, thread_root_id = ?, author_agent_id = ? WHERE message_id = ?", [run, source, CallJSON.agent, answer])
        try await f.settle()
        let go = try button("Go to answer", in: f.row(source).sources)
        XCTAssertEqual(f.model.sourceStatuses.first?.answer, answer)
        try f.base.write("UPDATE requests SET publication = 'withheld', version = 5 WHERE request_id = ?", [id])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(f.model.sourceStatuses, [.init(id: id, source: source, agent: "billing", state: "finished",
            initiator: CallJSON.boris, owner: f.base.key.accountId, publication: "withheld", error: nil, answer: answer)])
        XCTAssertNotNil(f.model.message(answer), "The answer exists; rejection must be the publication predicate")
        go.performClick(nil)
        XCTAssertFalse(actions.performSource(.answer, messageID: source, requestID: id))
        XCTAssertNil(f.model.revealMessageID); XCTAssertNil(f.model.threadRoot); XCTAssertFalse(f.model.hasNavigationReturn)
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        XCTAssertEqual(try f.base.commands(), before)
        let afterMarks = try await f.base.store.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description) }
        XCTAssertEqual(afterMarks, marks)
    }

    func testMembershipAuthorityRechecksBodyScopeMentionAndAddableState() async throws {
        let f = try await fixture()
        let source = f.messages[0].id, second = UUID().uuidString.lowercased()
        try f.base.write("DELETE FROM agent_channels")
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        for (id, name) in [(CallJSON.agent, "first"), (second, "second")] {
            try f.base.write("""
                INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available)
                VALUES (?, ?, ?, '', 'read', 1, 1)
                """, [id, f.base.key.accountId, name])
        }
        try f.base.write("UPDATE messages SET text = '@first@anna Please check.' WHERE message_id = ?", [source])
        let previousTeam = TeamService.sharedForTesting, previousHost = TabRouter.shared.ensureHost
        let previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
            engineFactory: { XCTFail("Rejected membership actions must not launch a terminal"); return TestEngine() }, optionsProvider: { _ in nil })
        TabRouter.shared.ensureHost = { workspace }
        defer {
            workspace.terminate(); TabRouter.shared.ensureHost = previousHost
            TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.sharedForTesting = previousOrg
        }
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let actions = try XCTUnwrap(f.adapter.actions), before = try f.base.commands()
        let original = try XCTUnwrap(f.model.message(source))
        let add = try button("Add @first@anna to channel", in: f.row(source).membership)
        func reject(_ id: String, _ reason: String) throws {
            XCTAssertFalse(actions.addAgent(messageID: source, agentID: id), reason)
            XCTAssertNil(workspace.popups.visibleConversation, reason)
            XCTAssertEqual(try f.base.commands(), before, reason)
        }
        let org = try XCTUnwrap(ChatOrgCurrent.shared.model), card = try XCTUnwrap(org.visibleChannel(f.model.channel))
        XCTAssertEqual(Set(org.addableAgents(card).map(\.agentId)), Set([CallJSON.agent, second]))
        try reject(second, "An addable but unmentioned agent is not this message's action")

        try f.base.write("UPDATE messages SET deleted_at = ? WHERE message_id = ?", [ChatTimelineReferenceFixture.date, source])
        try await Task.sleep(for: .milliseconds(80))
        var deleted = original; deleted.deletedAt = ChatTimelineReferenceFixture.date
        XCTAssertEqual(f.model.message(source), deleted)
        add.performClick(nil)
        try reject(CallJSON.agent, "A retained Add control cannot act after deletion")

        try f.base.write("UPDATE messages SET deleted_at = NULL, has_mutable = 0 WHERE message_id = ?", [source])
        try await Task.sleep(for: .milliseconds(80))
        var loading = original; loading.hasMutable = false
        XCTAssertEqual(f.model.message(source), loading)
        XCTAssertTrue(loading.loading); XCTAssertFalse(loading.text.isEmpty); XCTAssertNil(loading.localState)
        add.performClick(nil)
        try reject(CallJSON.agent, "Retained text is not a current mutable body")

        try f.base.write("UPDATE messages SET has_mutable = 1 WHERE message_id = ?", [source])
        try f.base.write("UPDATE agents_catalog SET enabled = 0 WHERE agent_id = ?", [CallJSON.agent])
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        XCTAssertEqual(f.model.message(source), original)
        let disabled = try XCTUnwrap(ChatOrgCurrent.shared.model).missingAgentMentions(in: original.text, channel: f.model.channel,
            catalog: f.base.store.calls.catalog())
        XCTAssertEqual(disabled.map { S.MembershipHint(agentID: $0.id, address: $0.address, canAdd: $0.canAdd, guidance: $0.guidance) },
            [.init(agentID: CallJSON.agent, address: "first@anna", canAdd: false, guidance: "Enable the agent, then add it to request an answer.")])
        try reject(CallJSON.agent, "The visible hint is disabled, so only canAdd rejects")

        try f.base.write("UPDATE agents_catalog SET enabled = 1 WHERE agent_id = ?", [CallJSON.agent])
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let otherKey = ChatOrgKey(server: f.base.key.server, accountId: f.base.key.accountId, orgId: UUID().uuidString.lowercased())
        let other = try guardService(directory: f.directory.appendingPathComponent("other-org"), key: otherKey, channel: f.model.channel)
        other.orgCurrent.refresh(other)
        let otherStore = try XCTUnwrap(other.orgSessions[otherKey]?.store), otherOrg = try XCTUnwrap(other.orgCurrent.model)
        let otherView = try await otherStore.queue.read(ChatOrgView.read)
        otherOrg.set(otherView)
        ChatOrgCurrent.sharedForTesting = other.orgCurrent
        XCTAssertNotEqual(otherOrg.key, f.model.key)
        let wrongScopeHints = try otherOrg.missingAgentMentions(in: original.text, channel: f.model.channel, catalog: f.base.store.calls.catalog())
        XCTAssertEqual(wrongScopeHints.map { S.MembershipHint(agentID: $0.id, address: $0.address, canAdd: $0.canAdd, guidance: $0.guidance) },
            [.init(agentID: CallJSON.agent, address: "first@anna", canAdd: true, guidance: "Add it to request an answer.")])
        try reject(CallJSON.agent, "Matching fixture IDs in another current organization cannot grant this row authority")
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
    }

    func testRetainedRequestAuthorityRejectsFeedRemovedTailAndMismatchedOwners() async throws {
        let f = try await ChatNativeRetainedRequestFixture(); retained.append(f)
        let actions = ChatTimelineActions(model: f.model, root: f.rootID,
            conversation: ChatTimelineAdapter.conversation(f.model, root: f.rootID))
        defer { actions.invalidate() }
        actions.update(archived: false, mentionable: [], ownerModel: f.owner)
        var opened: [String] = [], sessions: [[String]] = []
        actions.requestDetails = { id, _ in opened.append(id) }
        let previousOpen = TeamUI.openTab
        TeamUI.openTab = { sessions.append([$0, $1, $2]) }
        defer { TeamUI.openTab = previousOpen }
        let before = try f.base.commands()
        func reject(_ owner: ChatChannelOwnerModel, _ reason: String) throws {
            actions.update(archived: false, mentionable: [], ownerModel: owner)
            XCTAssertFalse(actions.openRequest(requestID: f.requestID), reason)
            XCTAssertFalse(actions.openRequestSession(requestID: f.requestID), reason)
            XCTAssertEqual(opened, [], reason); XCTAssertEqual(sessions, [], reason)
            XCTAssertEqual(try f.base.commands(), before, reason)
        }
        XCTAssertEqual(f.model.threadRoot, f.rootID); XCTAssertEqual(f.model.threadRequests.map(\.id), [f.requestID])
        XCTAssertFalse(f.model.sourceStatuses.contains { $0.id == f.requestID }); XCTAssertTrue(f.owner.visible)

        let feed = ChatTimelineActions(model: f.model, root: nil,
            conversation: ChatTimelineAdapter.conversation(f.model, root: nil))
        defer { feed.invalidate() }
        feed.update(archived: false, mentionable: [], ownerModel: f.owner)
        feed.requestDetails = { id, _ in opened.append(id) }
        XCTAssertFalse(feed.openRequest(requestID: f.requestID)); XCTAssertFalse(feed.openRequestSession(requestID: f.requestID))
        XCTAssertEqual(opened, []); XCTAssertEqual(sessions, [])

        let otherChannel = UUID().uuidString.lowercased()
        try f.base.write("""
            INSERT INTO channels (channel_id, team_id, name, archived, version, stamp)
            SELECT ?, team_id, 'another-channel', 0, version, stamp FROM channels WHERE channel_id = ?
            """, [otherChannel, f.model.channel])
        let channelOwner = ChatChannelOwnerModel(service: f.base.service, key: f.base.key, channel: otherChannel)
        XCTAssertTrue(channelOwner.visible); XCTAssertEqual(channelOwner.key, f.model.key)
        XCTAssertTrue(channelOwner.service === f.model.service)
        try reject(channelOwner, "Owner is for another visible channel")

        let otherService = try guardService(directory: f.directory.appendingPathComponent("other-service"), key: f.base.key, channel: f.model.channel)
        let serviceOwner = ChatChannelOwnerModel(service: otherService, key: f.base.key, channel: f.model.channel)
        XCTAssertTrue(serviceOwner.visible); XCTAssertEqual(serviceOwner.key, f.model.key); XCTAssertEqual(serviceOwner.channel, f.model.channel)
        XCTAssertFalse(serviceOwner.service === f.model.service)
        try reject(serviceOwner, "Same identifiers in a different fixture service do not share authority")

        // Keep the old model and actions mounted while this service changes its
        // current organization, as can happen before a close callback is delivered.
        // Same session ID avoids changing executor-session authority in this test.
        let originalConnection = try XCTUnwrap(f.base.service.connection)
        let otherKey = ChatOrgKey(server: f.base.key.server, accountId: f.base.key.accountId, orgId: UUID().uuidString.lowercased())
        try seedGuardOrganization(service: f.base.service, key: otherKey, channel: f.model.channel, sessionID: originalConnection.sessionId)
        defer { try? f.base.service.saveSignIn(originalConnection, token: "test-only") }
        let keyOwner = ChatChannelOwnerModel(service: f.base.service, key: otherKey, channel: f.model.channel)
        XCTAssertTrue(keyOwner.visible); XCTAssertTrue(keyOwner.service === f.model.service)
        XCTAssertEqual(keyOwner.channel, f.model.channel); XCTAssertNotEqual(keyOwner.key, f.model.key)
        XCTAssertTrue(f.base.service.orgSessions[f.base.key]?.store === f.base.store)
        XCTAssertEqual(f.model.threadRequests.map(\.id), [f.requestID])
        try reject(keyOwner, "Current owner key differs from the mounted timeline key")
        try f.base.service.saveSignIn(originalConnection, token: "test-only")

        f.base.service.orgSessions[f.base.key]?.snapshotOwed = true
        XCTAssertFalse(f.owner.visible)
        try reject(f.owner, "Current rights require another snapshot")
        f.base.service.orgSessions[f.base.key]?.snapshotOwed = false

        let otherRoot = UUID().uuidString.lowercased()
        try f.base.write("""
            INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
            VALUES (?, ?, ?, 2, ?, 1, 1, 'Another fixture thread.', '[]', 1)
            """, [otherRoot, f.model.channel, f.base.key.accountId, ChatTimelineReferenceFixture.date])
        try f.base.write("UPDATE requests SET thread_root_id = ? WHERE request_id = ?", [otherRoot, f.requestID])
        try await f.settle()
        XCTAssertEqual(f.model.threadRoot, f.rootID); XCTAssertEqual(f.model.threadRequests, [])
        XCTAssertFalse(f.model.sourceStatuses.contains { $0.id == f.requestID }); XCTAssertTrue(f.owner.visible)
        XCTAssertEqual(try f.base.request(f.requestID).threadRootId, otherRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.transcriptURL.path), "The retained run still exists; moving its request also fails the underlying session scope")
        try reject(f.owner, "Request belongs to another thread now")
        XCTAssertEqual(try f.base.commands(), before)
    }

    func testSourceExpansionThresholdAndRemovedMessagePresentationAreScoped() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        let source = f.messages[0].id, other = f.messages[1].id, actions = try XCTUnwrap(f.adapter.actions)
        actions.toggleSources(messageID: source)
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        var requests: [String] = []
        for count in 1...4 {
            let id = UUID().uuidString.lowercased(); requests.append(id)
            try f.base.move("running", 1, id: id)
            try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ? WHERE request_id = ?",
                [source, f.base.key.accountId, id])
            try await f.settle()
            XCTAssertEqual(f.model.sourceStatuses.filter { $0.source == source }.count, count)
            if count <= 3 {
                actions.toggleSources(messageID: source)
                XCTAssertEqual(actions.sourcePresentation(messageID: source), .init(), "\(count) source cards do not expand")
            }
        }
        let before = try f.base.commands()
        actions.toggleSources(messageID: source)
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init(expanded: true, problem: nil))
        XCTAssertEqual(actions.sourcePresentation(messageID: other), .init())
        let request = try XCTUnwrap(requests.first)
        try f.base.write("UPDATE requests SET state = 'approved', version = 2 WHERE request_id = ?", [request])
        XCTAssertEqual(f.model.sourceStatuses.first { $0.id == request }?.state, "running")
        XCTAssertTrue(actions.performSource(.stop, messageID: source, requestID: request))
        XCTAssertEqual(actions.sourcePresentation(messageID: source),
            .init(expanded: true, problem: "Only a call that is running can be stopped."))
        XCTAssertEqual(try f.base.commands(), before)
        // Same persisted message identity moves out of this pane; no fake model setter.
        try f.base.write("UPDATE messages SET thread_root_id = ? WHERE message_id = ?", [other, source])
        try await f.settle()
        XCTAssertFalse(f.model.conversationMessages(root: nil).contains { $0.id == source })
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        XCTAssertEqual(actions.sourcePresentation(messageID: other), .init())
        try f.base.write("UPDATE messages SET thread_root_id = NULL WHERE message_id = ?", [source])
        try await f.settle()
        XCTAssertTrue(f.model.conversationMessages(root: nil).contains { $0.id == source })
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        XCTAssertEqual(try f.base.commands(), before)
    }

    func testRequestProblemIsPrunedWhenRetainedCardLeavesCurrentThread() async throws {
        let f = try await ChatNativeRetainedRequestFixture(); retained.append(f)
        let actions = ChatTimelineActions(model: f.model, root: f.rootID,
            conversation: ChatTimelineAdapter.conversation(f.model, root: f.rootID))
        defer { actions.invalidate() }
        actions.update(archived: false, mentionable: [], ownerModel: f.owner)
        let previousOpen = TeamUI.openTab
        var sessions: [[String]] = []
        TeamUI.openTab = { sessions.append([$0, $1, $2]) }
        defer { TeamUI.openTab = previousOpen }
        let before = try f.base.commands(), data = try f.takeTranscript()
        XCTAssertTrue(actions.openRequestSession(requestID: f.requestID))
        try f.restoreTranscript(data)
        XCTAssertEqual(actions.requestProblem(requestID: f.requestID), "This conversation is not available through the channel on this Mac.")
        XCTAssertEqual(sessions, []); XCTAssertEqual(try f.base.commands(), before)
        let otherRoot = UUID().uuidString.lowercased()
        try f.base.write("""
            INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
            VALUES (?, ?, ?, 2, ?, 1, 1, 'A different fixture thread.', '[]', 1)
            """, [otherRoot, f.model.channel, f.base.key.accountId, ChatTimelineReferenceFixture.date])
        try f.base.write("UPDATE requests SET thread_root_id = ? WHERE request_id = ?", [otherRoot, f.requestID])
        try await f.settle()
        XCTAssertEqual(f.model.threadRequests, [])
        actions.update(archived: false, mentionable: [], ownerModel: f.owner)
        XCTAssertNil(actions.requestProblem(requestID: f.requestID))
        try f.base.write("UPDATE requests SET thread_root_id = ? WHERE request_id = ?", [f.rootID, f.requestID])
        try await f.settle()
        actions.update(archived: false, mentionable: [], ownerModel: f.owner)
        XCTAssertEqual(f.model.threadRequests.map(\.id), [f.requestID])
        XCTAssertNil(actions.requestProblem(requestID: f.requestID))
        XCTAssertEqual(sessions, []); XCTAssertEqual(try f.base.commands(), before)
    }

    func testLocalMembershipBodyOpensExistingConsentWhileSendingAndFailed() async throws {
        let f = try await fixture()
        try f.base.write("DELETE FROM agent_channels")
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        try f.base.write("""
            INSERT OR REPLACE INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, available)
            VALUES (?, ?, 'first', '', 'read', 1, 1)
            """, [CallJSON.agent, f.base.key.accountId])
        let previousTeam = TeamService.sharedForTesting, previousHost = TabRouter.shared.ensureHost
        let previousOrg = ChatOrgCurrent.sharedForTesting
        TeamService.sharedForTesting = f.base.teamService
        ChatOrgCurrent.sharedForTesting = f.base.service.orgCurrent
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, sessionNames: .testing,
            engineFactory: { XCTFail("Membership consent must not launch a terminal"); return TestEngine() }, optionsProvider: { _ in nil })
        TabRouter.shared.ensureHost = { workspace }
        defer {
            workspace.terminate(); TabRouter.shared.ensureHost = previousHost
            TeamService.sharedForTesting = previousTeam; ChatOrgCurrent.sharedForTesting = previousOrg
        }
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let text = "@first@anna Please check this local message."
        let source = try f.base.service.post(f.base.key, channel: f.model.channel, root: nil, text: text, mentions: [])
        try await f.settle()
        try ChatTimelineReferenceCapture.prepareOrganization(f.base.service)
        let sending = try XCTUnwrap(f.model.message(source))
        XCTAssertFalse(sending.hasMutable); XCTAssertFalse(sending.hasFixed)
        XCTAssertEqual(sending.localState, .sending); XCTAssertEqual(sending.text, text)
        for state in [ChatMessage.LocalState.sending, .failed] {
            var expected = sending
            if state == .failed {
                try f.base.write("UPDATE messages SET local_state = 'failed', local_error = 'forbidden' WHERE message_id = ?", [source])
                try f.base.write("UPDATE outbox SET state = 'failed', error = 'forbidden' WHERE type = 'message.post'")
                expected.localState = .failed; expected.localError = "forbidden"
                try await f.settle()
            }
            XCTAssertEqual(f.model.message(source), expected)
            XCTAssertEqual(try message(f, source).content.membershipHints,
                [.init(agentID: CallJSON.agent, address: "first@anna", canAdd: true, guidance: "Add it to request an answer.")])
            let before = try f.base.commands()
            try button("Add @first@anna to channel", in: f.row(source).membership).performClick(nil)
            let session = try XCTUnwrap(workspace.popups.visibleConversation)
            let conversation = try XCTUnwrap(session.channelConversation), consent = conversation.confirmation
            XCTAssertEqual(session.channel, ChannelRef(f.base.key, channel: f.model.channel))
            XCTAssertTrue(conversation.showingAgents)
            XCTAssertEqual(consent.context?.targetID, "agent:" + CallJSON.agent)
            XCTAssertEqual(consent.context?.scope, OrgKey(f.base.key))
            XCTAssertEqual(consent.title, "Add first to #billing?")
            XCTAssertEqual(consent.phase, .awaiting)
            XCTAssertEqual(f.model.message(source), expected)
            XCTAssertEqual(try f.base.commands(), before, "Opening consent cannot add or ask an agent")
            XCTAssertFalse(try f.base.commands().contains { $0.type.hasPrefix("request.create") })
            // Close the fixture consent without acceptance or focus restoration.
            consent.invalidate()
        }
    }

    func testSourceAnswerRejectsMissingTargetAndMissingAnswerFromRetainedControl() async throws {
        let f = try await fixture(count: 2)
        try f.base.write("UPDATE meta SET agents_served = 1 WHERE id = 1")
        f.base.service.isServerKnown = { _, _ in true }
        let id = UUID().uuidString.lowercased(), run = UUID().uuidString.lowercased()
        let source = f.messages[0].id, answer = f.messages[1].id
        try f.base.move("finished", 1, id: id, run: run, publication: "published")
        try f.base.write("UPDATE requests SET source_message_id = ?, owner_account_id = ?, initiator_account_id = ? WHERE request_id = ?",
            [source, f.base.key.accountId, CallJSON.boris, id])
        try f.base.write("UPDATE messages SET run_id = ?, thread_root_id = ?, author_agent_id = ? WHERE message_id = ?",
            [run, source, CallJSON.agent, answer])
        try f.base.write("INSERT OR REPLACE INTO read_marks (channel_id, last_read_seq, muted) VALUES (?, 1, 1)", [f.model.channel])
        try await f.settle()
        let actions = try XCTUnwrap(f.adapter.actions), go = try button("Go to answer", in: f.row(source).sources)
        let statuses = f.model.sourceStatuses, before = try f.base.commands()
        XCTAssertEqual(statuses, [.init(id: id, source: source, agent: "billing", state: "finished",
            initiator: CallJSON.boris, owner: f.base.key.accountId, publication: "published", error: nil, answer: answer)])
        let marks = try await f.base.store.queue.read {
            try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
        }
        // A real synchronous cache removal creates the race: the source observation
        // retains its answer ID while message(_:) queries the current database.
        try f.base.write("DELETE FROM messages WHERE message_id = ?", [answer])
        XCTAssertEqual(f.model.sourceStatuses, statuses)
        XCTAssertNil(f.model.message(answer))
        go.performClick(nil)
        XCTAssertFalse(actions.performSource(.answer, messageID: source, requestID: id))
        XCTAssertNil(f.model.revealMessageID); XCTAssertNil(f.model.threadRoot); XCTAssertFalse(f.model.hasNavigationReturn)
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        XCTAssertEqual(try f.base.commands(), before)

        // Let only the real model observation settle; retain the same mounted
        // button so its next invocation must re-resolve the now-absent answer ID.
        try await Task.sleep(for: .milliseconds(80))
        var missing = try XCTUnwrap(statuses.first); missing.answer = nil
        XCTAssertEqual(f.model.sourceStatuses, [missing])
        XCTAssertTrue(ChatSourcePresentation(missing, me: f.base.key.accountId, connected: true).answered)
        go.performClick(nil)
        XCTAssertFalse(actions.performSource(.answer, messageID: source, requestID: id))
        XCTAssertNil(f.model.revealMessageID); XCTAssertNil(f.model.threadRoot); XCTAssertFalse(f.model.hasNavigationReturn)
        XCTAssertEqual(actions.sourcePresentation(messageID: source), .init())
        XCTAssertEqual(try f.base.commands(), before)
        let afterMarks = try await f.base.store.queue.read {
            try Row.fetchAll($0, sql: "SELECT * FROM read_marks ORDER BY channel_id").map(\.description)
        }
        XCTAssertEqual(afterMarks, marks)
    }
}
