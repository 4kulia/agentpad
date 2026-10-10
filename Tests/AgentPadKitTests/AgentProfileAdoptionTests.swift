import XCTest
@testable import AgentPadKit

private final class AdoptionIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var resolutions = 0
    private var mainThread = false
    var executorReads: Int { lock.withLock { reads } }
    var folderReads: Int { lock.withLock { resolutions } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func executors() -> Set<String> {
        lock.withLock { reads += 1; mainThread = mainThread || Thread.isMainThread }
        return []
    }
    func folder(_ url: URL) -> AgentProfileAdoption.Folder {
        lock.withLock { resolutions += 1; mainThread = mainThread || Thread.isMainThread }
        return .read(url)
    }
}

@MainActor
final class AgentProfileAdoptionTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var stores: [WorkspaceStore] = []
    private var settings: AgentPadSettingsModel!
    private var previousSettings: AgentPadSettingsModel?
    private var file: URL { root.appendingPathComponent("profiles.json") }
    private var io: AgentProfileAdoption.IO {
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        return .init(executorIDs: { try ExecutorConversations(files: files).ids() })
    }

    override func setUp() async throws {
        // Adoption deliberately excludes every system temporary/cache folder.
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentpad-adoption-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profiles = AgentProfileStore(fileURL: file, adoptionIO: io)
        previousSettings = AgentPadSettingsModel.testModel
        settings = AgentPadSettingsModel(read: { [:] }, write: { _ in }, appliesRuntimeEffects: false)
        AgentPadSettingsModel.testModel = settings
    }

    override func tearDown() async throws {
        await profiles.waitForTabAdoption()
        try profiles.flush()
        stores.forEach { $0.terminate() }; stores = []
        AgentPadSettingsModel.testModel = previousSettings
        try FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return canonicalDiskPath(url)
    }

    private func tab(_ template: AgentTemplate, _ folder: URL, conversation: String? = nil) -> PersistedTab {
        PersistedTab(id: UUID(), agentId: template.id, currentDirectoryPath: folder.path, conversationId: conversation)
    }

    private func state(_ workspaces: [[PersistedTab]]) -> PersistedState {
        let workspaces = workspaces.map { tabs in
            let pane = PersistedPane(id: UUID(), tabs: tabs, activeTabId: tabs.first?.id)
            return PersistedWorkspace(id: UUID(), workingDirectoryPath: root.path,
                root: PersistedPaneNode(id: pane.id, kind: .pane(pane)), activePaneId: pane.id)
        }
        return PersistedState(workspaces: workspaces, activeWorkspaceId: workspaces.first?.id, agentTabRepair119Applied: true)
    }

    private func store(_ persistence: any Persistence = InMemoryPersistence(),
                       options: @escaping @MainActor (String) -> String? = { _ in "" },
                       visibility: @escaping () -> ChannelConversationFilter = { .init(channelIds: []) },
                       resume: Bool = false) -> WorkspaceStore {
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            engineFactory: { TestEngine() }, optionsProvider: options, resumeProvider: { resume },
            conversationVisibility: visibility, peerStores: { [weak self] in self?.stores ?? [] },
            claudeProjectsRoot: root.appendingPathComponent("no-transcripts"),
            codexSessionsRoot: root.appendingPathComponent("no-rollouts"))
        stores.append(store)
        return store
    }

    private func record(_ conversation: String, _ cwd: URL, agent: String = "codex") -> AgentSessionRecord {
        AgentSessionRecord(agentId: agent, conversationId: conversation, title: "Personal", cwd: cwd, lastActivity: .now)
    }

    private func launchBytes(_ session: Session) throws -> Data {
        let config = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last)
        var environment = config.environment
        // Every spawn deliberately generates a new exit-marker nonce.
        environment.removeValue(forKey: "AGENTPAD_LAUNCH_ID")
        return try JSONSerialization.data(withJSONObject: ["command": config.command, "arguments": config.arguments,
            "cwd": config.workingDirectory ?? "", "environment": environment], options: .sortedKeys)
    }

    func testOwnerStateJSONRestoresEveryWindowAndHiddenWorkspaceWithoutReportsOrCatalogAcrossTwoRestarts() async throws {
        let a = try folder("a"), b = try folder("b"), conversation = UUID().uuidString
        let customData = CustomAgentData(id: "custom-codex", baseAgentId: "codex")
        settings.customAgents = [customData]
        let custom = AgentTemplate.fromCustom(customData)
        var frozen = tab(.codex, a)
        frozen.launchOrigin = AgentLaunchOrigin(template: .codex, folder: a, options: "--model frozen")
        let windows = [
            PersistedWindow(id: UUID(), state: state([
                [tab(.terminal, a), tab(.claudeCode, a), tab(.codex, a)],
                [tab(.claudeCode, b, conversation: conversation), tab(.codex, b), tab(custom, a)]
            ])),
            PersistedWindow(id: UUID(), state: state([[tab(.codex, a), frozen, tab(.gemini, b)]]))
        ]
        let stateFile = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(PersistedApp(windows: windows)).write(to: stateFile)
        var expectedProfiles: [AgentProfile]?
        for restart in 0...2 {
            let app = AppPersistence(fileURL: stateFile)
            for id in app.windowIds {
                _ = store(WindowPersistence(windowId: id, app: app), options: { "--model \($0)-original" })
            }
            let before = stores.flatMap(\.allSessions).map(PersistedTab.init)
            XCTAssertEqual(before.count, 9)
            XCTAssertTrue(stores.flatMap(\.allSessions).allSatisfy { $0.engine.foregroundPid == nil }, "No PTYs or reports, including hidden never-spawned tabs")
            await profiles.waitForTabAdoption()
            XCTAssertEqual(profiles.profiles.count, 7)
            XCTAssertEqual(profiles.bindings.count, 1)
            XCTAssertEqual(profiles.binding(agentID: "claude-code", conversationID: conversation)?.record.cwd, b)
            XCTAssertEqual(Set(profiles.profiles.map(\.name)), ["a", "b"])
            for profile in profiles.profiles {
                let expected = profile.templateID == "codex" && profile.launchOptions == "--model frozen"
                    ? "--model frozen" : "--model \(profile.templateID)-original"
                XCTAssertEqual(profile.launchOptions, expected)
            }
            for (session, previous) in zip(stores.flatMap(\.allSessions), before) {
                var after = PersistedTab(session)
                if !session.agent.isShell {
                    XCTAssertNotNil(session.profileID.flatMap(profiles.profile))
                    XCTAssertEqual(session.profileOriginalCwd, session.profileAdoption?.folder)
                }
                after.profileID = previous.profileID; after.profileOriginalCwd = previous.profileOriginalCwd
                XCTAssertEqual(after, previous, "Only the persisted profile association changes")
            }
            XCTAssertTrue(profiles.details.archive.origins.isEmpty, "Legacy origins must not be invented")
            if let expectedProfiles { XCTAssertEqual(Set(profiles.profiles.map(\.id)), Set(expectedProfiles.map(\.id))) }
            else { expectedProfiles = profiles.profiles }
            for session in stores.flatMap(\.allSessions) where !session.agent.isShell {
                let config = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last)
                let options = session.launchOrigin?.options ?? "--model \(session.agent.id)-original"
                XCTAssertTrue(try XCTUnwrap(config.environment["AGENTPAD_AGENT"]).contains(options), "Restart \(restart): \(session.agent.id)")
            }
            try profiles.flush()
            for owner in stores { XCTAssertTrue(owner.flushPersistence()); owner.terminate() }
            stores = []
            profiles = AgentProfileStore(fileURL: file, adoptionIO: io)
        }
    }

    func testExecutorSavedIDIsCheckedBeforeResumeDropsItAndLostIDLimitationIsAccepted() async throws {
        let project = try folder("executor"), id = UUID().uuidString
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        try ExecutorConversations(files: files).record(id)
        let memory = InMemoryPersistence(initial: state([[tab(.terminal, project)], [tab(.claudeCode, project, conversation: id)]]))
        let owner = store(memory, visibility: { .current(journalURL: files.journalURL) }, resume: true)
        XCTAssertNil(owner.allSessions[1].conversationId, "Resume refuses the executor ID")
        await profiles.waitForTabAdoption()
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertTrue(profiles.bindings.isEmpty)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles.count, 1, "Accepted: after a restart loses the ID, its harmless profile can be adopted")
        XCTAssertEqual(restored.allSessions[1].profileID, profiles.profiles.first?.id)
        XCTAssertTrue(profiles.bindings.isEmpty)
    }

    func testExecutorStoreIsCheckedForEveryAgentAndUnreadableStoreCanRetryOnTabMove() async throws {
        let project = try folder("project"), id = UUID().uuidString
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        let executors = ExecutorConversations(files: files)
        try executors.record(id)
        let owner = store(InMemoryPersistence(initial: state([[tab(.codex, project, conversation: id.uppercased())]])))
        await profiles.waitForTabAdoption()
        XCTAssertTrue(profiles.profiles.isEmpty)
        try Data("unreadable".utf8).write(to: executors.url)
        let personal = owner.addTab(in: owner.active!, template: .codex, initialCwd: project)
        await profiles.waitForTabAdoption()
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertNotNil(profiles.problem)
        try FileManager.default.removeItem(at: executors.url)
        try executors.record(id)
        XCTAssertNotNil(owner.moveTabToNewWorkspace(personal.id))
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertTrue(profiles.bindings.isEmpty)
    }

    func testCreationAndWorkspaceMovesUseLaunchFolderAndOptionsAndLaterReportsBindLinkedTab() async throws {
        let launch = try folder("launch"), later = try folder("later")
        let settings = settings!
        settings.agentOptions["codex"] = "--model launch"
        let owner = store(options: { settings.agentOptions[$0] })
        let session = owner.addTab(in: owner.active!, template: .codex, initialCwd: launch)
        let original = session.profileAdoption
        session.engine.onPwdChange?(later.path)
        settings.agentOptions["codex"] = "--model changed-after-launch"
        let guess = UUID().uuidString
        owner.applyConversationId(conversationId: guess, sessionId: session.id)
        await profiles.waitForTabAdoption()
        let profile = try XCTUnwrap(profiles.profiles.first)
        XCTAssertEqual(profile.folder, launch)
        XCTAssertEqual(profile.launchOptions, "--model launch")
        XCTAssertEqual(session.profileID, profile.id); XCTAssertEqual(session.profileOriginalCwd, launch)
        XCTAssertTrue(profiles.bindings.isEmpty, "A Codex heuristic report cannot create a binding, even before adoption executes")
        let peer = store()
        XCTAssertTrue(peer.handleTabDrop(droppedId: session.id, in: peer.active!))
        XCTAssertNotNil(peer.moveTabToNewWorkspace(session.id))
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles, [profile])
        XCTAssertEqual(session.profileAdoption?.folder, original?.folder)
        XCTAssertTrue(profiles.bindings.isEmpty)
        owner.applyConversationId(conversationId: guess, sessionId: session.id)
        peer.applyHookConversationId(conversationId: guess, sessionId: session.id)
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: guess)?.profileID, profile.id)
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: guess)?.record.cwd, launch)
        XCTAssertEqual(profiles.profiles, [profile], "Reports bind an already-linked tab, without running adoption")
    }

    func testConcurrentCodexReportsDoNotMergeOptionsOrBindBeforeAdoption() async throws {
        let project = try folder("project"), owner = store(options: { _ in "--model first" })
        let first = owner.addTab(in: owner.active!, template: .codex, initialCwd: project)
        let second = owner.addTab(in: owner.active!, template: .codex, initialCwd: project,
            launchOrigin: AgentLaunchOrigin(template: .codex, folder: project, options: "--model second"))
        let guess = UUID().uuidString
        try profiles.discover([record(guess, project)])
        for tab in [first, second] { owner.applyConversationId(conversationId: guess, sessionId: tab.id) }
        await profiles.waitForTabAdoption()
        XCTAssertEqual(Set(profiles.profiles.map(\.launchOptions)), ["--model first", "--model second"])
        XCTAssertTrue(profiles.bindings.isEmpty)
        XCTAssertNotNil(first.profileID); XCTAssertNotNil(second.profileID)
        XCTAssertNotEqual(first.profileID, second.profileID)
    }

    func testCreatedAndReusedProfilesLinkEveryLiveTabPersistAndKeepHistoryAfterClose() async throws {
        for reuse in [false, true] {
            let project = try folder("live-\(reuse)"), memory = InMemoryPersistence()
            let existing = reuse ? try profiles.add(template: .codex, folder: project, name: "Keep name") : nil
            let owner = store(memory), workspace = try XCTUnwrap(owner.active)
            let sessions = (0..<2).map { _ in owner.addTab(in: workspace, template: .codex, initialCwd: project) }
            await profiles.waitForTabAdoption()
            let profile = try XCTUnwrap(sessions[0].profileID.flatMap(profiles.profile))
            if let existing { XCTAssertEqual(profile, existing) }
            XCTAssertTrue(sessions.allSatisfy { $0.profileID == profile.id && $0.profileOriginalCwd == project })
            XCTAssertEqual(Set(owner.profileSessionItems(profile).map(\.id)), Set(sessions.map { $0.id.uuidString }))
            XCTAssertTrue(profiles.records(for: profile.id).isEmpty)
            // Exercise adoption's own debounced persistence, without flushing it explicitly.
            for _ in 0..<200 where memory.saved == nil { try await Task.sleep(for: .milliseconds(10)) }
            let persisted = try XCTUnwrap(memory.saved)
            guard case .pane(let pane) = persisted.workspaces[0].root.kind else { return XCTFail("Expected one pane") }
            XCTAssertEqual(pane.tabs.map(\.profileID), [profile.id, profile.id])

            let conversation = UUID().uuidString
            for session in sessions {
                owner.applyHookConversationId(conversationId: conversation, sessionId: session.id)
            }
            XCTAssertEqual(owner.profileSessionItems(profile).count, 2, "Same conversation still has two live tabs")
            _ = owner.addTab(in: workspace)
            for session in sessions { owner.closeTab(session, in: workspace) }
            let history = try XCTUnwrap(owner.profileSessionItems(profile).first)
            XCTAssertNil(history.session)
            XCTAssertEqual(history.record?.conversationId, conversation)
            XCTAssertEqual(history.cwd, project)
            try profiles.flush()
            XCTAssertEqual(AgentProfileStore(fileURL: file).binding(agentID: "codex", conversationID: conversation)?.profileID, profile.id)
            owner.terminate()
        }
    }

    func testAdoptionKeepsRelaunchParametersByteIdenticalForCreatedAndReusedProfiles() async throws {
        let customData = CustomAgentData(id: "custom-codex", baseAgentId: "codex", env: "API_URL=https://example.invalid")
        settings.customAgents = [customData]
        for template in [AgentTemplate.claudeCode, .codex, .fromCustom(customData)] {
            for reuse in [false, true] {
                for hasOrigin in [false, true] {
                    let project = try folder("bytes-\(template.id)-\(reuse)-\(hasOrigin)")
                    let options = hasOrigin ? "" : "  --model 'original model'  --config x=\"a b\"  "
                    if reuse { _ = try profiles.add(template: template, folder: project, launchOptions: options) }
                    var saved = tab(template, project, conversation: UUID().uuidString)
                    if hasOrigin { saved.launchOrigin = AgentLaunchOrigin(template: template, folder: project, options: options) }
                    var memory = InMemoryPersistence(initial: state([[saved]]))
                    var owner = store(memory, options: { _ in options }, resume: template.rosterId == "codex")
                    let before = try launchBytes(XCTUnwrap(owner.allSessions.first))
                    for _ in 0..<2 {
                        await profiles.waitForTabAdoption()
                        let session = try XCTUnwrap(owner.allSessions.first)
                        XCTAssertEqual(try launchBytes(session), before)
                        let profile = try XCTUnwrap(session.profileID.flatMap(profiles.profile))
                        XCTAssertEqual(profile.templateID, template.id)
                        XCTAssertEqual(Data(profile.launchOptions.utf8), Data(options.utf8))
                        XCTAssertEqual(profile.folder, project)
                        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
                        memory = InMemoryPersistence(initial: try XCTUnwrap(memory.saved))
                        owner = store(memory, options: { _ in "--model changed-global" }, resume: template.rosterId == "codex")
                        XCTAssertEqual(try launchBytes(XCTUnwrap(owner.allSessions.first)), before)
                    }
                    owner.terminate()
                }
            }
        }
    }

    func testRestoreFolderPrecedencePinsKeyBindingAndRelaunchToSameFolder() async throws {
        for source in ["origin", "profile", "current"] {
            let origin = try folder("\(source)-origin"), pinned = try folder("\(source)-profile"), osc = try folder("\(source)-osc")
            let conversation = UUID().uuidString
            var saved = tab(.codex, osc, conversation: conversation)
            if source != "current" { saved.profileOriginalCwd = pinned }
            if source == "origin" { saved.launchOrigin = AgentLaunchOrigin(template: .codex, folder: origin, options: "") }
            let expected = source == "origin" ? origin : source == "profile" ? pinned : osc
            let memory = InMemoryPersistence(initial: state([[saved]])), owner = store(memory, resume: true)
            let session = try XCTUnwrap(owner.allSessions.first), before = try launchBytes(session)
            await profiles.waitForTabAdoption()
            let profile = try XCTUnwrap(session.profileID.flatMap(profiles.profile))
            XCTAssertEqual(profile.folder, expected)
            XCTAssertEqual(session.profileOriginalCwd, expected)
            XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: conversation)?.record.cwd, profile.folder)
            XCTAssertTrue(owner.flushPersistence()); owner.terminate()
            let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)), resume: true)
            XCTAssertEqual(try launchBytes(XCTUnwrap(restored.allSessions.first)), before)
            restored.terminate()
        }
    }

    func testProfileButtonReportsKeepHistoryAfterCloseAndMovedProfileDoesNotReadoptOldFolder() async throws {
        let original = try folder("button-original"), moved = try folder("button-moved"), osc = try folder("button-osc")
        let profile = try profiles.add(template: .codex, folder: original, launchOptions: "--model own")
        let memory = InMemoryPersistence(), owner = store(memory)
        let session = try owner.startAgentProfile(profile.id).get()
        try profiles.move(profile.id, to: moved)
        session.engine.onPwdChange?(osc.path)
        XCTAssertNotNil(owner.moveTabToNewWorkspace(session.id))
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles.map(\.id), [profile.id], "A linked tab never creates a profile for the old folder")
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
        let tab = try XCTUnwrap(restored.allSessions.first { $0.id == session.id })
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles.map(\.id), [profile.id])
        XCTAssertEqual(tab.profileID, profile.id)
        let conversation = UUID().uuidString
        restored.applyConversationId(conversationId: conversation, sessionId: tab.id)
        let binding = try XCTUnwrap(profiles.binding(agentID: "codex", conversationID: conversation))
        XCTAssertEqual(binding.profileID, profile.id)
        XCTAssertEqual(binding.record.cwd, original)
        let workspace = try XCTUnwrap(restored.location(ofSessionId: tab.id)?.workspace)
        _ = restored.addTab(in: workspace)
        restored.closeTab(tab, in: workspace)
        let row = try XCTUnwrap(restored.profileSessionItems(profile).first)
        XCTAssertNil(row.session)
        XCTAssertEqual(row.record?.conversationId, conversation)
        XCTAssertEqual(profiles.details.archive.origins[binding.id]?.options, "--model own")
        try profiles.flush()
        XCTAssertEqual(AgentProfileStore(fileURL: file).binding(agentID: "codex", conversationID: conversation), binding)
    }

    func testManualShellUpgradeAdoptsAtUpgradeCwdAndOnlyUpgradeRetriesAdoption() async throws {
        let reads = AdoptionIOProbe()
        profiles = AgentProfileStore(fileURL: file, adoptionIO: .init(executorIDs: { reads.executors() }, folder: { reads.folder($0) }))
        for agent in [AgentTemplate.claudeCode, .codex] {
            let shellCwd = try folder("\(agent.id)-shell"), launch = try folder("\(agent.id)-launch"), later = try folder("\(agent.id)-later")
            let owner = store(options: { _ in "--model manual" })
            let session = owner.addTab(in: owner.active!, initialCwd: shellCwd)
            await profiles.waitForTabAdoption()
            let priorReads = reads.executorReads, previous = UUID().uuidString
            owner.applyConversationId(conversationId: previous, sessionId: session.id)
            await profiles.waitForTabAdoption()
            XCTAssertEqual(reads.executorReads, priorReads)
            XCTAssertNil(session.profileAdoption)
            session.engine.onPwdChange?(launch.path)
            owner.applyHookEvent(agent: agent, event: .running, sessionId: session.id)
            session.engine.onPwdChange?(later.path)
            let conversation = UUID().uuidString
            owner.applyHookConversationId(conversationId: conversation, sessionId: session.id)
            await profiles.waitForTabAdoption()
            let profile = try XCTUnwrap(session.profileID.flatMap(profiles.profile))
            XCTAssertEqual(profile.templateID, agent.id)
            XCTAssertEqual(profile.folder, launch)
            XCTAssertEqual(profile.launchOptions, "--model manual")
            XCTAssertEqual(session.profileOriginalCwd, launch)
            XCTAssertEqual(reads.executorReads, priorReads + 1)
            XCTAssertNil(profiles.binding(agentID: agent.rosterId, conversationID: previous))
            XCTAssertNil(profiles.binding(agentID: agent.rosterId, conversationID: conversation), "Only the frozen upgrade candidate was adopted")
            // Subsequent reports use the established profile-launch binding path.
            owner.applyHookEvent(agent: agent, event: .running, sessionId: session.id)
            owner.applyHookConversationId(conversationId: conversation, sessionId: session.id)
            await profiles.waitForTabAdoption()
            XCTAssertEqual(reads.executorReads, priorReads + 1, "Ordinary reports never rerun adoption")
            XCTAssertEqual(profiles.binding(agentID: agent.rosterId, conversationID: conversation)?.record.cwd, launch)
            owner.applyHookEvent(agent: agent, event: .ended, sessionId: session.id)
            owner.applyHookEvent(agent: agent, event: .running, sessionId: session.id)
            await profiles.waitForTabAdoption()
            XCTAssertEqual(session.profileID.flatMap(profiles.profile)?.folder, later, "A second manual launch refreshes the candidate")
            owner.terminate()
        }
    }

    func testExistingProfileAndBindingRemainImmutableAndPinnedFolderWins() async throws {
        let original = try folder("original"), moved = try folder("moved"), other = try folder("osc")
        let id = UUID().uuidString
        let profile = try profiles.add(template: .codex, folder: original, name: "Keep this name", launchOptions: "--model own")
        try profiles.bind(record(id, other), to: profile.id)
        try profiles.move(profile.id, to: moved)
        let existing = try XCTUnwrap(profiles.profile(profile.id)), binding = try XCTUnwrap(profiles.binding(agentID: "codex", conversationID: id))
        var saved = tab(.codex, other, conversation: id)
        saved.profileOriginalCwd = moved
        let owner = store(InMemoryPersistence(initial: state([[saved]])), options: { _ in "--model own" })
        let before = PersistedTab(owner.allSessions[0])
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles, [existing])
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: id), binding)
        XCTAssertEqual(PersistedTab(owner.allSessions[0]), before)
    }

    func testFileIdentityAndCanonicalPathReuseExistingProfileAcrossWindows() async throws {
        let project = try folder("Project"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let existing = try profiles.add(template: .codex, folder: project, name: "Keep me", launchOptions: "--model same")
        let a = store(options: { _ in "--model same" }), b = store(options: { _ in "--model same" })
        _ = a.addTab(in: a.active!, template: .codex, initialCwd: alias)
        // Inject the canonical spelling unchanged to exercise the identity index too.
        profiles = AgentProfileStore(fileURL: file, adoptionIO: .init(executorIDs: { [] }, folder: { url in
            let read = AgentProfileAdoption.Folder.read(url)
            return .init(url: url, identity: read.identity, isDirectory: read.isDirectory)
        }))
        let c = store(options: { _ in "--model same" })
        _ = c.addTab(in: c.active!, template: .codex, initialCwd: alias)
        _ = b.addTab(in: b.active!, template: .codex, initialCwd: project)
        await a.agentProfiles.waitForTabAdoption()
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles, [existing])
        XCTAssertEqual(a.agentProfiles.profiles, [existing])
    }

    func testFolderExclusionsUsePathBoundariesAndRejectSymlinkTargets() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let excluded = [home.path, "/", NSTemporaryDirectory(), NSTemporaryDirectory() + "child",
            "/tmp", "/tmp/child", "/private/tmp", "/private/tmp/child",
            "/private/var/folders/ab/session", "/var/folders/ab/session", home.path + "/Library",
            home.path + "/Library/Application Support/project", home.path + "/library/project", home.path + "/.cache/project",
            "/Library/Caches/project", root.path + "/.cache/session", "/var/cache/session"]
        for path in excluded { XCTAssertFalse(AgentProfileStore.isAdoptableFolder(URL(fileURLWithPath: path)), path) }
        for path in [root.path, home.path + "/Library-project", home.path + "/.cache-project", "/tmp-project", "/private/var/folders-project"] {
            XCTAssertTrue(AgentProfileStore.isAdoptableFolder(URL(fileURLWithPath: path)), path)
        }
        let alias = root.appendingPathComponent("temporary-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: FileManager.default.temporaryDirectory)
        let owner = store()
        for cwd in [home, URL(fileURLWithPath: "/"), FileManager.default.temporaryDirectory, alias, try folder(".cache/child")] {
            _ = owner.addTab(in: owner.active!, template: .codex, initialCwd: cwd)
        }
        await profiles.waitForTabAdoption()
        XCTAssertTrue(profiles.profiles.isEmpty)
    }

    func testShellSSHChannelInboxContentAndUnknownTemplatesAreSkipped() async throws {
        let project = try folder("project")
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")
        var ssh = tab(.codex, project); ssh.sshWorkspaceHost = "host"
        var unknown = tab(.codex, project); unknown.agentId = "deleted-template"
        var channel = tab(.codex, project); channel.channel = ChannelRef(key, channel: "test")
        var inbox = tab(.codex, project); inbox.inbox = ChatInboxRef(key, kind: .unread)
        var content = tab(.codex, project); content.content = .tool(.allSessions)
        let owner = store(InMemoryPersistence(initial: state([[tab(.terminal, project), ssh, unknown, channel, inbox, content]])))
        XCTAssertEqual(owner.allSessions.count, 6)
        await profiles.waitForTabAdoption()
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertTrue(profiles.bindings.isEmpty)
    }

    func testHundredTabsReadExecutorStoreOnceResolveLinearlyAndWriteOnceOffMain() async throws {
        let writes = ProfileArchiveWriteProbe(), reads = AdoptionIOProbe()
        profiles = AgentProfileStore(fileURL: file, write: { try writes.write($0, to: $1) },
            adoptionIO: .init(executorIDs: { reads.executors() }, folder: { reads.folder($0) }))
        let tabs = try (0..<100).map { tab(.codex, try folder("project-\($0)"), conversation: UUID().uuidString) }
        _ = store(InMemoryPersistence(initial: state([Array(tabs.prefix(50)), Array(tabs.suffix(50))])), options: { _ in "--model original" })
        await profiles.waitForTabAdoption()
        XCTAssertEqual(profiles.profiles.count, 100)
        XCTAssertEqual(profiles.bindings.count, 100)
        XCTAssertEqual(reads.executorReads, 1)
        XCTAssertEqual(reads.folderReads, 100, "One canonicalization/identity lookup per folder, no pairwise sameItem")
        XCTAssertFalse(reads.ranOnMain)
        XCTAssertEqual(writes.count, 0, "No synchronous per-tab commits")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(writes.wroteOnMain)
        XCTAssertEqual(AgentProfileStore(fileURL: file).profiles.count, 100)
        XCTAssertEqual(AgentProfileStore(fileURL: file).bindings.count, 100)
    }

    func testFailedAdoptionSaveRetriesOnTabMoveWithoutChangingExplicitEdits() async throws {
        let writes = ProfileArchiveWriteProbe(), project = try folder("project")
        profiles = AgentProfileStore(fileURL: file, write: { try writes.write($0, to: $1) }, adoptionIO: io)
        writes.fail = true
        let owner = store(), tab = owner.addTab(in: owner.active!, template: .codex, initialCwd: project)
        await profiles.waitForTabAdoption()
        for _ in 0..<100 where profiles.problem == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(profiles.problem)
        let id = try XCTUnwrap(profiles.profiles.first?.id)
        writes.fail = false
        XCTAssertNotNil(owner.moveTabToNewWorkspace(tab.id))
        await profiles.waitForTabAdoption()
        try profiles.rename(id, to: "Keep this edit")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(AgentProfileStore(fileURL: file).profile(id)?.name, "Keep this edit")
        XCTAssertEqual(profiles.profiles.count, 1)
    }
}
