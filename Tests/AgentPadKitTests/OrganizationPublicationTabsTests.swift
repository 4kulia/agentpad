import XCTest
@testable import AgentPadKit

@MainActor
final class OrganizationPublicationTabsTests: XCTestCase {
    private var root: URL!
    private var router: TabRouter!
    private var tabs: TeamTabs!
    private var service: TeamService!
    private var stores: [WorkspaceStore] = []
    private var drafts: DraftRepository!
    private var publishing: Publishing!
    private var org: ChatOrgModel!
    private var key: ChatOrgKey!
    private var teamScope: TeamServiceTestScope!

    private final class Publishing: TeamPublishing {
        var sent: [[TeamPublishedAgent]] = []
        var removed: [UUID] = []
        var assignments: [UUID: ChatOrgKey] = [:]
        var teams: [UUID: [String]] = [:]
        var failure: Error?
        func isAssigned(_ id: UUID) -> Bool { assignments[id] != nil }
        func assignmentKey(_ id: UUID) -> ChatOrgKey? { assignments[id] }
        func publish(_ agents: [TeamPublishedAgent], teams: [String], key: ChatOrgKey) throws {
            if let failure { throw failure }
            sent.append(agents)
            for agent in agents { assignments[agent.id] = key; self.teams[agent.id] = teams }
        }
        func unpublish(_ id: UUID, key: ChatOrgKey) throws { removed.append(id) }
    }

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("group4-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = TeamService(storage: TeamStorage(directory: root.appendingPathComponent("team")), offCalls: TeamOffCallStore())
        await service.load()
        service.calls.conversationVisibility = { ChannelConversationFilter(channelIds: []) }
        publishing = Publishing(); service.calls.publishing = publishing
        router = TabRouter(); router.stores = { [weak self] in self?.stores ?? [] }
        tabs = TeamTabs(router: router)
        tabs.serviceProvider = { [unowned self] in service }
        tabs.assignment = { [unowned self] in publishing.assignmentKey($0) }
        tabs.chosenTeams = { [unowned self] id, _ in publishing.teams[id] }
        tabs.connectionIdentity = { "session-1" }
        drafts = DraftRepository(fileURL: root.appendingPathComponent("drafts.json"))
        key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.test"), accountId: "me", orgId: "org")
    }
    override func tearDown() async throws {
        stores.forEach { $0.terminate() }; stores = []
        org = nil; service = nil; tabs = nil; router = nil
        try? FileManager.default.removeItem(at: root)
        teamScope.close(); teamScope = nil
    }
    private func store() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), drafts: drafts,
            engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store); router.ensureHost = { [weak store] in store }
        return store
    }
    private func server() throws {
        let cache = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("chat")), key: key).store
        service.calls.serverMode = true; service.calls.useServer(cache.calls, key: key)
        org = ChatOrgModel(me: key.accountId) { _, _ in "command" }
        org.key = key
        org.set(ChatOrgView(members: [.init(accountId: key.accountId, handle: "me", name: "Me", role: "owner")],
            teams: [.init(teamId: "general", name: "General", isGeneral: true, archived: false, mine: true, members: [key.accountId])], followsAdmin: true))
        tabs.organization = { [unowned self] in org }
    }
    private func fields(_ state: TabState, name: String = "backend") -> PublicationFormState {
        let form = tabs.form(state)
        form.fields.name = name; form.fields.description = "Answers about the backend"; form.fields.folder = root.path
        return form
    }
    private func save(_ state: TabState) async throws {
        let scope = try XCTUnwrap(state.route.teamScope)
        try await tabs.save(state, fields: tabs.form(state).fields, scope: scope, identity: tabs.connectionIdentity())
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out")
    }
    private func conversation() throws -> String {
        let id = UUID().uuidString.lowercased()
        let projects = root.appendingPathComponent("projects")
        let project = projects.appendingPathComponent("-test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path, "sessionId": id])
        try data.write(to: project.appendingPathComponent(id + ".jsonl"))
        service.calls.sessionFilesRoot = projects
        return id
    }

    func testListCardAndSessionConvergeAndTransferKeepsTheEditor() async throws {
        let a = store(), b = store(), conversation = try conversation()
        var agent = TeamPublishedAgent(name: "backend", description: "Backend", folder: root.path)
        agent.access = .read; agent.sessionId = conversation
        try await service.calls.save(agent)
        let editing = TeamAgentEditing(agent: agent, key: nil)
        let first = try XCTUnwrap(tabs.showPublication(editing, from: a))
        let state = try XCTUnwrap(first.tabState)
        tabs.form(state).fields.budgetText = "invalid budget"
        XCTAssertTrue(tabs.showPublication(editing, from: b) === first)
        XCTAssertTrue(tabs.publish(sessionID: conversation, title: "New title", surfaceID: UUID(), from: b) === first)
        XCTAssertTrue(b.handleTabDrop(droppedId: first.id, in: try XCTUnwrap(b.active)))
        XCTAssertTrue(router.owner(of: first.id)?.store === b)
        XCTAssertEqual(tabs.form(state).fields.budgetText, "invalid budget")
        XCTAssertEqual((first.engine as? NativeTabEngine)?.starts, 0)
        XCTAssertEqual(stores.flatMap(\.allSessions).filter { $0.toolRoute == first.toolRoute }.count, 1)
    }

    func testInvalidDraftRestartsWithAllFieldsAndPinnedSourceWithoutSending() async throws {
        let a = store(), id = try conversation(), surface = UUID()
        let session = try XCTUnwrap(tabs.publish(sessionID: id, title: "Source", surfaceID: surface, from: a))
        let state = try XCTUnwrap(session.tabState), form = tabs.form(state)
        await tabs.loadSource(state)
        form.fields.name = "bad name"; form.fields.budgetText = "not a number"
        form.fields.extraText = "/missing\n\n"; form.fields.commandsText = "bad[command"
        form.fields.deniedText = "*.secret\n"; form.fields.modelText = "typed model"
        form.fields.mode = .both; form.fields.folderName = "typed folder"
        form.fields.maxTurns = 17; form.fields.timeoutMinutes = 9
        form.fields.teamIDs = ["unavailable-team"]
        let expected = form.fields, route = state.route
        tabs.requestSave(state)
        XCTAssertNotNil(form.error); XCTAssertFalse(state.confirmation.isAwaiting)
        XCTAssertTrue(tabs.publish(sessionID: id, title: "Changed", surfaceID: surface, from: a) === session)
        try a.tabCloseCoordinator.save(state)
        let saved = try XCTUnwrap(state.draft)
        a.closeTab(session, in: try XCTUnwrap(a.active))
        drafts = DraftRepository(fileURL: root.appendingPathComponent("drafts.json"))
        XCTAssertEqual(drafts.draft(saved.id), saved)
        let b = store(), restored = try XCTUnwrap(router.open(route, from: b)?.tabState)
        XCTAssertEqual(tabs.form(restored).fields, expected)
        XCTAssertTrue(publishing.sent.isEmpty); XCTAssertTrue(service.calls.agents.isEmpty)
        let second = try XCTUnwrap(tabs.publish(sessionID: id, surfaceID: surface, from: b, newDraft: true))
        XCTAssertNotEqual(second.toolRoute, restored.route)
    }

    func testSaveRekeysSameTabAfterMoveAndDoubleConfirmationDoesNotDuplicate() async throws {
        let a = store(), b = store()
        let session = try XCTUnwrap(tabs.publish(from: a)), state = try XCTUnwrap(session.tabState)
        let form = fields(state), agentID = form.fields.agentID
        tabs.requestSave(state)
        XCTAssertTrue(state.confirmation.isAwaiting)
        XCTAssertTrue(b.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(b.active)))
        XCTAssertEqual(state.confirmation.phase, .invalidated)
        tabs.requestSave(state); state.confirmation.canShow = { true }; state.confirmation.shown(true)
        state.confirmation.confirm(); state.confirmation.confirm()
        try await settle { state.confirmation.phase == .completed }
        XCTAssertEqual(service.calls.agents.map(\.id), [agentID])
        XCTAssertEqual(session.toolRoute, .publication(.local, publicationID: agentID.uuidString.lowercased()))
        XCTAssertTrue(router.owner(of: session.id)?.store === b)
        XCTAssertNil(state.draft); XCTAssertTrue(drafts.drafts.isEmpty)
    }

    func testRightsAndVersionAreCheckedAfterPreparationWithoutLosingEdits() async throws {
        try server(); let a = store()
        let session = try XCTUnwrap(tabs.publish(from: a)), state = try XCTUnwrap(session.tabState)
        let form = fields(state), entered = form.fields
        service.calls.afterPrepare = { [unowned self] in org.set(ChatOrgView(rightsInDoubt: true)) }
        do { try await save(state); XCTFail("Rights were lost") } catch {}
        XCTAssertEqual(form.fields, entered); XCTAssertTrue(service.calls.agents.isEmpty)
        XCTAssertTrue(publishing.sent.isEmpty)
        try server(); service.calls.afterPrepare = {}
        try await save(state)
        let old = try XCTUnwrap(service.calls.agents.first)
        form.fields.description = "My unsaved edit"
        service.calls.afterPrepare = { [unowned self] in
            var changed = old; changed.description = "Changed elsewhere"
            try? await service.calls.save(changed)
        }
        do { try await save(state); XCTFail("Version changed") } catch {}
        XCTAssertEqual(form.fields.description, "My unsaved edit")
        XCTAssertEqual(service.calls.agents.first?.description, "Changed elsewhere")
        XCTAssertEqual(publishing.sent.count, 1)
    }

    func testSaveCompletionUsesTheNewOwnerAfterTransferDuringPreparation() async throws {
        try server(); let a = store(), b = store()
        let session = try XCTUnwrap(tabs.publish(from: a)), state = try XCTUnwrap(session.tabState)
        let form = fields(state), id = form.fields.agentID
        service.calls.afterPrepare = {
            XCTAssertTrue(b.handleTabDrop(droppedId: session.id, in: b.active!))
            a.terminate()
        }
        try await save(state)
        XCTAssertTrue(router.owner(of: session.id)?.store === b)
        XCTAssertEqual(session.toolRoute, .publication(.server(OrgKey(key)), publicationID: id.uuidString.lowercased()))
        XCTAssertEqual(publishing.sent.count, 1)
        XCTAssertNil(state.draft); XCTAssertTrue(drafts.drafts.isEmpty)
    }

    func testLateSavePreservesNewerDraftAfterCloseReopenAndClose() async throws {
        try server(); let a = store(), workspace = try XCTUnwrap(a.active)
        let session = try XCTUnwrap(tabs.publish(from: a)), state = try XCTUnwrap(session.tabState)
        let form = fields(state), submittedText = form.fields.description
        try a.tabCloseCoordinator.save(state)
        let submitted = try XCTUnwrap(state.draft)
        var newer: TabDraft?
        service.calls.afterPrepare = { [unowned self] in
            a.closeTab(session, in: workspace)
            let reopened = try! XCTUnwrap(a.reopenLastClosedTab())
            let reopenedState = try! XCTUnwrap(reopened.tabState)
            tabs.form(reopenedState).fields.description = "New edits while the first Save is running"
            try! a.tabCloseCoordinator.save(reopenedState)
            newer = reopenedState.draft
            a.closeTab(reopened, in: workspace)
        }
        try await save(state)
        let kept = try XCTUnwrap(newer)
        XCTAssertEqual(kept.id, submitted.id)
        XCTAssertGreaterThan(kept.revision, submitted.revision)
        XCTAssertEqual(service.calls.agents.first?.description, submittedText)
        XCTAssertEqual(drafts.draft(kept.id), kept)
        XCTAssertEqual(DraftRepository(fileURL: root.appendingPathComponent("drafts.json")).draft(kept.id), kept)
        let reopened = try XCTUnwrap(a.reopenLastClosedTab()?.tabState)
        XCTAssertEqual(tabs.form(reopened).fields.description, "New edits while the first Save is running")
    }

    func testLateSavePreservesNewerInputInTheSameEditor() async throws {
        try server(); let a = store()
        let state = try XCTUnwrap(tabs.publish(from: a)?.tabState), form = fields(state)
        let route = state.route, submittedText = form.fields.description
        var newer: TabDraft?
        service.calls.afterPrepare = {
            form.fields.description = "Newer input"
            try! a.tabCloseCoordinator.save(state)
            newer = state.draft
        }
        try await save(state)
        XCTAssertEqual(service.calls.agents.first?.description, submittedText)
        XCTAssertEqual(state.draft, newer)
        XCTAssertEqual(state.route, route)
        XCTAssertEqual(form.fields.description, "Newer input")
        XCTAssertEqual(drafts.draft(try XCTUnwrap(newer).id), newer)
    }

    func testPublishExistingSessionKeepsSourceAndBindsAgainAfterSignIn() async throws {
        try server(); let a = store(), conversation = try conversation()
        let source = try XCTUnwrap(a.active?.activeSession)
        source.agent = .claudeCode
        let process = AnswerProcessFixture()
        try process.bind(source, conversation: conversation)
        tabs.sourceInspector = process.inspector
        var agent = TeamPublishedAgent(name: "session", description: "Published session", folder: root.path)
        agent.access = .read; agent.sessionId = conversation
        try await service.calls.save(agent)
        try publishing.publish([agent], teams: ["general"], key: key)
        let first = try XCTUnwrap(tabs.showPublication(TeamAgentEditing(agent: agent, key: key), from: a))
        a.closeTab(first, in: try XCTUnwrap(a.active))
        tabs.connectionIdentity = { "session-2" }

        let session = try XCTUnwrap(tabs.publish(sessionID: conversation, title: "Live source", surfaceID: source.id, from: a))
        let state = try XCTUnwrap(session.tabState), form = tabs.form(state)
        XCTAssertEqual(form.fields.sourceSurfaceID, source.id)
        XCTAssertEqual(form.fields.sourceConversationID, conversation)
        form.fields.description = "Keep these edits"
        XCTAssertTrue(tabs.publish(sessionID: conversation, surfaceID: source.id, from: a) === session)
        XCTAssertEqual(form.fields.description, "Keep these edits")
        var bound: [UUID] = []
        tabs.bindPublication = { requestedKey, id, surface in
            XCTAssertEqual(requestedKey, self.key)
            XCTAssertEqual(surface, source.id)
            bound.append(id)
        }
        try await save(state)
        XCTAssertEqual(bound, [agent.id])
        XCTAssertEqual(form.fields.sourceSurfaceID, source.id)
        XCTAssertEqual(form.fields.sourceConversationID, conversation)
    }

    func testReviewResolvesFolderVersionAndTeamsInFolderAndBothModes() async throws {
        try server(); let a = store()
        tabs.bindPublication = { _, _, _ in }
        for mode in [TeamPublishMode.folder, .both] {
            let conversation = try conversation()
            var folder = TeamPublishedAgent(name: "folder-\(mode.rawValue)", description: "Original folder", folder: root.path)
            folder.access = .read
            try await service.calls.save(folder)
            if mode == .both {
                var agent = TeamPublishedAgent(name: "session-both", description: "Original session", folder: root.path)
                agent.access = .read; agent.sessionId = conversation
                try await service.calls.save(agent)
            }
            let state = try XCTUnwrap(tabs.publish(sessionID: conversation, title: "New source", from: a, newDraft: true)?.tabState)
            await tabs.loadSource(state)
            let form = tabs.form(state)
            form.fields.mode = mode; form.fields.folderName = folder.name
            tabs.updateFolderTarget(state)
            XCTAssertEqual(form.fields.folderAgentID, folder.id)
            form.fields.description = "My pending edits"
            folder.description = "Folder changed elsewhere"
            try await service.calls.save(folder)
            publishing.teams[folder.id] = ["general"]
            tabs.requestSave(state)
            XCTAssertNotNil(form.error)
            XCTAssertFalse(state.confirmation.isAwaiting)

            tabs.reviewCurrentVersion(state)
            XCTAssertTrue(state.confirmation.isAwaiting, "Review must include the folder target in \(mode)")
            XCTAssertTrue(state.confirmation.consequences.contains(folder.description))
            guard state.confirmation.isAwaiting else { continue }
            state.confirmation.canShow = { true }; state.confirmation.shown(true); state.confirmation.confirm()
            try await settle { state.confirmation.phase == .completed }
            let current = try XCTUnwrap(service.calls.agents.first { $0.id == folder.id })
            XCTAssertEqual(form.fields.versions[folder.id], PublicationDraft.version(current))
            XCTAssertEqual(form.fields.teamVersions[folder.id], ["general"])
            XCTAssertEqual(form.fields.description, "My pending edits")
            try await save(state)
            XCTAssertEqual(service.calls.agents.first { $0.id == folder.id }?.description, "My pending edits")
            XCTAssertNil(state.draft)
        }
    }

    func testPublicationFailureKeepsDraftAndRetryUsesTheSameAgent() async throws {
        try server(); let a = store()
        let state = try XCTUnwrap(tabs.publish(from: a)?.tabState), form = fields(state)
        let id = form.fields.agentID
        publishing.failure = ChatError.storage("Delivery failed")
        do { try await save(state); XCTFail("Expected delivery failure") } catch {}
        XCTAssertNotNil(state.draft); XCTAssertEqual(form.fields.name, "backend")
        XCTAssertEqual(service.calls.agents.map(\.id), [id])
        publishing.failure = nil
        try await save(state)
        XCTAssertEqual(service.calls.agents.map(\.id), [id])
        XCTAssertEqual(publishing.sent.count, 1)
        XCTAssertNil(state.draft)
    }

    func testPinnedSourceSurvivesMoveAndSaveWithoutReauthorizingAStoredSurface() async throws {
        try server(); let a = store(), b = store(), conversation = try conversation(), surface = UUID()
        let session = try XCTUnwrap(tabs.publish(sessionID: conversation, title: "Conversation", surfaceID: surface, from: a))
        let state = try XCTUnwrap(session.tabState)
        await tabs.loadSource(state)
        let form = tabs.form(state), folder = form.fields.folder
        XCTAssertTrue(b.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(b.active)))
        b.active?.workingDirectory = root.appendingPathComponent("elsewhere")
        var bound: [UUID?] = []
        tabs.bindPublication = { requestedKey, _, surface in
            XCTAssertEqual(requestedKey, self.key); bound.append(surface)
        }
        try await save(state)
        XCTAssertEqual(service.calls.agents.first?.folder, folder)
        XCTAssertEqual(service.calls.agents.first?.sessionId, conversation)
        XCTAssertEqual(bound.count, 1); XCTAssertNil(bound[0])
        XCTAssertEqual(form.fields.sourceSurfaceID, surface)
    }

    func testDraftWriteFailurePreventsSubmissionAndKeepsRawFields() throws {
        drafts = DraftRepository(fileURL: root.appendingPathComponent("failed-drafts.json")) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let a = store(), state = try XCTUnwrap(tabs.publish(from: a)?.tabState)
        let form = fields(state)
        form.fields.description = "My exact input\n"
        tabs.requestSave(state)
        XCTAssertFalse(state.confirmation.isAwaiting)
        XCTAssertNotNil(form.error)
        XCTAssertEqual(form.fields.description, "My exact input\n")
        XCTAssertTrue(service.calls.agents.isEmpty)
        var closed = false
        a.tabCloseCoordinator.request(try XCTUnwrap(a.active?.activeSession)) { closed = true }
        XCTAssertFalse(closed); XCTAssertNotNil(state.saveError)
    }

    func testBindingFailureAfterPublicationCanRetryWithTheSameSavedVersion() async throws {
        try server(); let a = store(), conversation = try conversation()
        let state = try XCTUnwrap(tabs.publish(sessionID: conversation, title: "Conversation", surfaceID: UUID(), from: a)?.tabState)
        await tabs.loadSource(state)
        let form = tabs.form(state), id = form.fields.agentID
        tabs.bindPublication = { _, _, _ in throw ChatError.storage("Binding could not be saved") }
        do { try await save(state); XCTFail("Expected binding failure") } catch {}
        XCTAssertEqual(form.fields.teamVersions[id], ["general"])
        XCTAssertNotNil(state.draft)
        tabs.bindPublication = { _, _, _ in }
        try await save(state)
        XCTAssertEqual(service.calls.agents.map(\.id), [id])
        XCTAssertEqual(Set(publishing.sent.flatMap { $0.map(\.id) }), [id])
        XCTAssertNil(state.draft)
    }

    func testScopeAndUnpublishDecisionsCannotFollowAnotherAccountOrLocalMode() async throws {
        try server(); let a = store()
        let state = try XCTUnwrap(tabs.publish(from: a)?.tabState)
        _ = fields(state); try await save(state)
        let agent = try XCTUnwrap(service.calls.agents.first)
        tabs.requestUnpublish([agent], state: state)
        state.confirmation.canShow = { true }; state.confirmation.shown(true)
        let other = ChatOrgKey(server: key.server, accountId: "another", orgId: key.orgId)
        let cache = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent("other")), key: other).store
        service.calls.useServer(cache.calls, key: other)
        state.confirmation.confirm()
        XCTAssertEqual(state.confirmation.phase, .invalidated); XCTAssertTrue(publishing.removed.isEmpty)
        XCTAssertFalse(tabs.canRead(.server(OrgKey(key))))
        service.calls.serverMode = false
        XCTAssertTrue(tabs.agents(.local).isEmpty, "Server assignments do not appear as local publications")
        XCTAssertNotEqual(tabs.showAgents(from: a)?.toolRoute, .publishedAgents(.server(OrgKey(key))))
    }

    func testOrganizationDecisionInvalidatesOnTargetRevisionAndKeepsRenameInput() async throws {
        var sent: [String] = []
        let model = ChatOrgModel(me: "me") { type, _ in sent.append(type); return "command" }
        let member = ChatOrgView.Member(accountId: "me", handle: "me", name: "Me", role: "owner")
        var team = ChatOrgView.Team(teamId: "ops", name: "Ops", isGeneral: false, archived: false, mine: true, members: ["me"])
        model.set(ChatOrgView(members: [member], teams: [team], followsAdmin: true))
        let state = TabState(route: .organization(OrgKey(key))), original = team
        OrganizationTabs.request(state, tabID: UUID(), target: team.id, title: "Archive Ops?", text: "Read only", verb: "Archive",
            valid: { model.teams.first == original && model.canChange(original) }) { try model.archiveTeam(original) }
        state.confirmation.shown(true)
        team.name = "Renamed elsewhere"
        model.set(ChatOrgView(members: [member], teams: [team], followsAdmin: true))
        try await settle { state.confirmation.phase == .invalidated }
        state.confirmation.confirm(); XCTAssertTrue(sent.isEmpty)
        let form = OrganizationFormState.form(state, model: model)
        form.fields.renameTeamID = team.id; form.fields.renameText = "bad\nname"
        form.rename(team, model: model)
        XCTAssertNotNil(form.renameError); XCTAssertEqual(form.fields.renameText, "bad\nname")
        form.fields.renameText = "New name"; form.rename(team, model: model)
        XCTAssertEqual(sent, ["team.rename"]); XCTAssertNil(form.fields.renameTeamID)
        team.archived = true
        model.set(ChatOrgView(members: [member], teams: [team], followsAdmin: true))
        form.fields.renameTeamID = team.id; form.fields.renameText = "Cannot rename"
        form.rename(team, model: model)
        XCTAssertNotNil(form.renameError); XCTAssertEqual(sent, ["team.rename"])
    }

    func testArchiveFromContextMenuOpensChannelForInlineConfirmation() async throws {
        let a = store(), shared = TabRouter.shared, previousHost = shared.ensureHost
        shared.ensureHost = { a }
        defer { shared.ensureHost = previousHost }
        var sent: [String] = []
        let failure = ChatError.storage("Archive failed")
        let model = ChatOrgModel(me: "me") { type, args in
            if !sent.isEmpty { throw failure }
            XCTAssertEqual(args["channel_id"]?.string, "channel")
            sent.append(type); return "command"
        }
        model.key = key
        let card = ChatChannelCard(channelId: "channel", teamId: "general", name: "Releases", createdBy: "me", archived: false, version: 1)
        model.set(ChatOrgView(members: [.init(accountId: "me", handle: "me", name: "Me", role: "owner")],
            teams: [.init(teamId: "general", name: "General", isGeneral: true, archived: false, mine: true, members: ["me"])],
            channels: [card], channelsServed: true))
        defer { model.isCurrent = { false } }
        ChatSidebarActions.archiveChannel(card, model)
        let session = try XCTUnwrap(a.channelTab(ChannelRef(key, channel: card.channelId))?.0,
            "Archive must reveal its channel's inline confirmation")
        let engine = try XCTUnwrap(session.engine as? ChannelTabEngine), confirmation = engine.conversation.confirmation
        XCTAssertTrue(a.active?.activeSession === session)
        XCTAssertTrue(confirmation.isAwaiting)
        XCTAssertEqual(confirmation.context?.tabID, session.id)
        XCTAssertEqual(confirmation.context?.scope, OrgKey(key))
        XCTAssertEqual(confirmation.context?.revision, "1")
        XCTAssertTrue(confirmation.title.contains(card.name))
        XCTAssertTrue(sent.isEmpty)
        confirmation.confirm()
        XCTAssertTrue(confirmation.isAwaiting, "A hidden confirmation cannot archive")
        confirmation.canShow = { true }; confirmation.shown(true); confirmation.cancel()
        XCTAssertTrue(sent.isEmpty)

        ChatSidebarActions.archiveChannel(card, model, from: a)
        confirmation.shown(true)
        var changed = model.view
        changed.channels[0].version += 1
        changed.channels[0].name = "Changed elsewhere"
        model.set(changed)
        try await settle { confirmation.phase == .invalidated }
        confirmation.confirm(); XCTAssertTrue(sent.isEmpty)

        let current = try XCTUnwrap(model.visibleChannel(card.channelId))
        ChatSidebarActions.archiveChannel(current, model, from: a)
        confirmation.shown(true); confirmation.confirm(); confirmation.confirm()
        try await settle { confirmation.phase == .completed }
        XCTAssertEqual(sent, ["channel.archive"])

        ChatSidebarActions.archiveChannel(current, model, from: a)
        confirmation.shown(true); confirmation.confirm()
        try await settle { if case .failed = confirmation.phase { return true }; return false }
        XCTAssertEqual(confirmation.phase, .failed(failure.localizedDescription))
        confirmation.confirm(); XCTAssertEqual(sent, ["channel.archive"])
    }

    func testArchiveConfirmationInvalidatesOnNavigationTransferAndConnectionChange() throws {
        let previousIdentity = TeamTabs.shared.connectionIdentity
        defer { TeamTabs.shared.connectionIdentity = previousIdentity }
        for reason in ["tab", "window", "move", "close", "connection", "rights"] {
            let a = store(), b = store()
            var identity = "sign-in-1"
            TeamTabs.shared.connectionIdentity = { identity }
            let model = ChatOrgModel(me: "me") { _, _ in XCTFail("Stale consent must not archive"); return "command" }
            model.key = key
            let card = ChatChannelCard(channelId: "channel", teamId: "general", name: "Releases", createdBy: "me", archived: false, version: 1)
            model.set(ChatOrgView(members: [.init(accountId: "me", handle: "me", name: "Me", role: "owner")],
                teams: [.init(teamId: "general", name: "General", isGeneral: true, archived: false, mine: true, members: ["me"])],
                channels: [card], channelsServed: true))
            ChatSidebarActions.archiveChannel(card, model, from: a)
            let session = try XCTUnwrap(a.channelTab(ChannelRef(key, channel: card.channelId))?.0)
            let confirmation = try XCTUnwrap(session.engine as? ChannelTabEngine).conversation.confirmation
            XCTAssertTrue(confirmation.isAwaiting)
            confirmation.canShow = { true }; confirmation.shown(true)
            switch reason {
            case "tab": _ = a.openToolTab(.settings)
            case "window": a.setOnScreen(false)
            case "move": XCTAssertTrue(b.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(b.active)))
            case "close": a.closeTab(session, in: try XCTUnwrap(a.active))
            case "connection": identity = "sign-in-2"
            default: model.set(ChatOrgView(rightsInDoubt: true))
            }
            confirmation.confirm()
            XCTAssertEqual(confirmation.phase, .invalidated, reason)
        }
    }
}
