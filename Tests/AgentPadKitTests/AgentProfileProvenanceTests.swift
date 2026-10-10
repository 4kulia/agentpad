import AppKit
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentProfileProvenanceTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var stores: [WorkspaceStore] = []
    override func setUp() async throws {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentpad-profile-origin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"))
    }
    override func tearDown() async throws {
        try profiles.flush()
        stores.forEach { $0.terminate() }; stores = []
        try FileManager.default.removeItem(at: root)
    }
    private func store(_ persistence: InMemoryPersistence = .init()) -> WorkspaceStore {
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            engineFactory: { TestEngine() }, optionsProvider: { _ in "--model original" }, resumeProvider: { false },
            peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store); return store
    }

    func testUnknownTranscriptDoesNotGuessOriginAndLiveTabUsesRecordedLaunch() async throws {
        let profile = try profiles.add(template: .codex, folder: root)
        let record = AgentSessionRecord(agentId: "codex", conversationId: UUID().uuidString, title: "unknown", cwd: root, lastActivity: Date())
        try profiles.discover([record])
        XCTAssertTrue(profiles.bindings.isEmpty)
        let owner = store(), session = owner.addTab(in: owner.active!, template: .codex, initialCwd: root)
        XCTAssertNil(session.profileID)
        session.launchOrigin = nil
        owner.applyConversationId(conversationId: record.conversationId, sessionId: session.id)
        await profiles.waitForTabAdoption()
        XCTAssertEqual(session.profileID.flatMap(profiles.profile)?.launchOptions, "--model original")
        XCTAssertNil(session.launchOrigin)
        XCTAssertTrue(profiles.details.archive.origins.isEmpty)
        XCTAssertTrue(profiles.bindings.isEmpty)
        XCTAssertEqual(profiles.profile(profile.id), profile)
        XCTAssertEqual(Set(profiles.profiles.map(\.launchOptions)), ["", "--model original"])
    }

    func testOptionsAndTemplateIdentitySurviveMoveCloseAndResume() throws {
        let owner = store()
        let profile = try profiles.add(template: .codex, folder: root, launchOptions: "--model original").id
        let first = try owner.startAgentProfile(profile).get()
        let conversation = UUID().uuidString
        owner.applyConversationId(conversationId: conversation, sessionId: first.id)
        first.currentDirectory = root.appendingPathComponent("later-cd")
        let binding = try XCTUnwrap(profiles.binding(agentID: "codex", conversationID: conversation))
        XCTAssertEqual(binding.record.cwd, canonicalDiskPath(root))
        _ = owner.addTab(in: owner.active!)
        owner.closeTab(first, in: owner.active!)
        let resumed = try owner.resumeProfileConversation(binding).get()
        XCTAssertEqual(resumed.profileID, profile)
        XCTAssertEqual(resumed.launchOrigin?.options, "--model original")
        XCTAssertEqual(resumed.launchOrigin?.folder, canonicalDiskPath(root))
        try profiles.flush()
        XCTAssertEqual(AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json")).details.archive.origins[binding.id], resumed.launchOrigin)
    }

    func testCustomTemplatesAndOptionsAreNotDuplicatesAndChangedEndpointIsRefused() throws {
        let a = AgentTemplate.fromCustom(CustomAgentData(id: "corp", baseAgentId: "claude-code", env: "API_URL=https://corp.invalid"))
        let b = AgentTemplate.fromCustom(CustomAgentData(id: "personal", baseAgentId: "claude-code"))
        let first = try profiles.add(template: a, folder: root)
        XCTAssertNotEqual(first.id, try profiles.add(template: b, folder: root).id)
        XCTAssertNotEqual(first.id, try profiles.add(template: a, folder: root, launchOptions: "--model opus").id)
        let origin = AgentLaunchOrigin(template: a, folder: root, options: "")
        XCTAssertFalse(origin.matches(AgentTemplate.fromCustom(CustomAgentData(id: "corp", baseAgentId: "claude-code", env: "API_URL=https://elsewhere.invalid"))))
        let record = AgentSessionRecord(agentId: a.rosterId, conversationId: UUID().uuidString, title: "corp history", cwd: root, lastActivity: Date())
        try profiles.bind(record, to: first.id, origin: origin)
        let owner = store(); owner.profileTemplates = { [b] }
        guard case .failure(.launchOriginUnavailable) = owner.resumeProfileConversation(profiles.bindings[0]) else { return XCTFail("Must not substitute another template") }
        XCTAssertTrue(owner.allSessions.isEmpty)
    }

    func testMappingPublicationsReplaysWithoutChangingSourcesOrMergingCustomProfiles() throws {
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "custom", baseAgentId: "claude-code"))
        let local = try profiles.add(template: custom, folder: root)
        let a = TeamPublishedAgent(name: "first", description: "", folder: root.path)
        var b = a; b.id = UUID(); b.name = "second"; b.access = .editFiles; b.sessionId = UUID().uuidString
        try profiles.mapPublications([a, b]); try profiles.mapPublications([a, b])
        XCTAssertEqual(profiles.profiles.count, 2)
        XCTAssertEqual(profiles.details.archive.publications[a.id.uuidString], profiles.details.archive.publications[b.id.uuidString])
        XCTAssertNotEqual(profiles.details.archive.publications[a.id.uuidString], local.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-profiles.json.backup").path))
        XCTAssertTrue(profiles.bindings.isEmpty, "A published fork must not become a personal session")
    }

    func testDoubleActivationStartsOnceAndOtherWindowHistoryFocusesExistingTab() throws {
        let a = store(), b = store(), profile = try profiles.add(template: .codex, folder: root)
        a.activateAgentProfile(profile.id, timestamp: 1)
        a.activateAgentProfile(profile.id, timestamp: 1.1)
        a.activateAgentProfile(profile.id, timestamp: 1 + max(0.65, NSEvent.doubleClickInterval) - 0.01)
        XCTAssertEqual(a.allSessions.count, 1)
        let item = try XCTUnwrap(b.profileSessionItems(profile).first)
        XCTAssertTrue(try b.openProfileSession(item, profileID: profile.id).get() === a.allSessions.first)
        XCTAssertTrue(b.allSessions.isEmpty)
        a.activateAgentProfile(profile.id, timestamp: 1 + max(0.65, NSEvent.doubleClickInterval) + 0.01)
        XCTAssertEqual(a.allSessions.count, 2)
    }
    func testManualRelaunchAfterWrapperEndDoesNotBorrowOldOptions() throws {
        let owner = store(), profile = try profiles.add(template: .codex, folder: root)
        let session = try owner.startAgentProfile(profile.id).get()
        let conversation = UUID().uuidString
        try profiles.discover([AgentSessionRecord(agentId: "codex", conversationId: conversation, title: "Personal", cwd: root, lastActivity: .now)])
        owner.applyConversationId(conversationId: conversation, sessionId: session.id)
        XCTAssertNotNil(session.profileID)
        owner.applyHookEvent(agent: .codex, event: .ended, sessionId: session.id)
        owner.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
        XCTAssertNil(session.launchOrigin)
        XCTAssertNil(session.profileID)
    }

    func testReopenRefusesChangedCustomEndpointWithoutStartingAnything() throws {
        let a = AgentTemplate.fromCustom(CustomAgentData(id: "custom", baseAgentId: "codex", env: "API_URL=https://original.invalid"))
        let b = AgentTemplate.fromCustom(CustomAgentData(id: "custom", baseAgentId: "codex", env: "API_URL=https://changed.invalid"))
        let owner = store(); owner.profileTemplates = { [a] }
        let session = owner.addTab(in: owner.active!, template: a, initialCwd: root)
        _ = owner.addTab(in: owner.active!)
        owner.closeTab(session, in: owner.active!)
        owner.profileTemplates = { [b] }
        let count = owner.allSessions.count
        XCTAssertNil(owner.reopenLastClosedTab())
        XCTAssertEqual(owner.allSessions.count, count)
    }

    private func legacyState(agentID: String, profile: AgentProfile, conversation: String) -> PersistedState {
        var tab = PersistedTab(id: UUID(), agentId: agentID, currentDirectoryPath: root.path, conversationId: conversation)
        tab.profileID = profile.id; tab.profileOriginalCwd = root
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let workspace = PersistedWorkspace(id: UUID(), workingDirectoryPath: root.path,
            root: PersistedPaneNode(id: pane.id, kind: .pane(pane)), activePaneId: pane.id)
        return PersistedState(workspaces: [workspace], activeWorkspaceId: workspace.id, agentTabRepair119Applied: true)
    }

    func testLegacyRestoreDoesNotInventOriginFromChangedTemplate() throws {
        let previousSettings = AgentPadSettingsModel.testModel
        let settings = AgentPadSettingsModel(read: { [:] }, write: { _ in }, appliesRuntimeEffects: false)
        AgentPadSettingsModel.testModel = settings
        defer { AgentPadSettingsModel.testModel = previousSettings }
        let old = AgentTemplate.fromCustom(CustomAgentData(id: "corp", baseAgentId: "codex", env: "API_URL=https://old.invalid"))
        settings.customAgents = [CustomAgentData(id: "corp", baseAgentId: "codex", env: "API_URL=https://new.invalid")]
        let profile = try profiles.add(template: old, folder: root), conversation = UUID().uuidString
        let memory = InMemoryPersistence(initial: legacyState(agentID: old.id, profile: profile, conversation: conversation))
        let owner = WorkspaceStore(persistence: memory, agentProfiles: profiles, engineFactory: { TestEngine() },
            optionsProvider: { _ in nil }, resumeProvider: { true })
        stores.append(owner)
        let tab = try XCTUnwrap(owner.active?.activeSession)
        XCTAssertEqual(tab.agent.id, old.id, "Legacy restore keeps the tab's recorded agent")
        XCTAssertEqual(tab.resumedConversationId, conversation)
        XCTAssertNil(tab.launchOrigin, "Today's endpoint is not evidence of the old launch")
        XCTAssertNil(profiles.details.archive.origins["codex:\(conversation)"])
        XCTAssertTrue(owner.flushPersistence())
        let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
        XCTAssertNil(restored.active?.activeSession?.launchOrigin)
        XCTAssertTrue(profiles.details.archive.origins.isEmpty)
    }

    func testLegacyClosedHistoryResumesRecordedAgentThroughProfileAndAllSessions() throws {
        let fixture = try ClaudeResumeFixture()
        for agent in [AgentTemplate.codex, .claudeCode] {
            let custom = AgentTemplate.fromCustom(CustomAgentData(id: "corp-\(agent.id)", baseAgentId: agent.id, env: "API_URL=https://profile.invalid"))
            let profile = try profiles.add(template: custom, folder: root, launchOptions: "--model profile-only")
            let record = AgentSessionRecord(agentId: agent.id, conversationId: fixture.id,
                title: "Legacy history", cwd: root, lastActivity: Date())
            try profiles.bind(record, to: profile.id)
            profiles = AgentProfileStore(fileURL: root.appendingPathComponent("agent-profiles.json"))
            for allSessions in [false, true] {
                let owner = store(); owner.profileTemplates = { [custom, agent] }; owner.claudeProjectsRoot = fixture.root
                let row = try XCTUnwrap(owner.profileSessionItems(profile).first)
                let session = try (allSessions ? owner.resumeAgentSession(record) : owner.openProfileSession(row, profileID: profile.id)).get()
                XCTAssertEqual(session.agent.id, record.agentId)
                XCTAssertEqual(session.resumedConversationId, record.conversationId)
                let command = try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"])
                XCTAssertFalse(command.contains("profile-only"), command)
                XCTAssertNil(session.launchOrigin)
                XCTAssertTrue(profiles.details.archive.origins.isEmpty)
                owner.terminate()
            }
        }
    }

    func testLegacyTabKeepsRecordedAgentWhenProfileUsesAnotherTemplate() throws {
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "profile-template", baseAgentId: "codex"))
        let profile = try profiles.add(template: custom, folder: root, launchOptions: "--model profile-only")
        let conversation = UUID().uuidString
        let owner = WorkspaceStore(persistence: InMemoryPersistence(initial: legacyState(agentID: "codex", profile: profile, conversation: conversation)),
            agentProfiles: profiles, engineFactory: { TestEngine() }, optionsProvider: { _ in nil }, resumeProvider: { true })
        stores.append(owner)
        let tab = try XCTUnwrap(owner.active?.activeSession)
        XCTAssertEqual(tab.agent.id, "codex")
        XCTAssertEqual(tab.resumedConversationId, conversation)
        XCTAssertNil(tab.launchOrigin)
        let command = try XCTUnwrap((tab.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"])
        XCTAssertFalse(command.contains("profile-only"), command)
        _ = owner.addTab(in: owner.active!)
        owner.closeTab(tab, in: owner.active!)
        let reopened = try XCTUnwrap(owner.reopenLastClosedTab())
        XCTAssertEqual(reopened.agent.id, "codex")
        XCTAssertEqual(reopened.resumedConversationId, conversation)
        XCTAssertNil(reopened.launchOrigin)
        XCTAssertTrue(profiles.details.archive.origins.isEmpty)
    }

    func testLegacyMissingAgentRestoresAllSessionsRecoveryInsteadOfUnavailableTab() throws {
        let removed = AgentTemplate.fromCustom(CustomAgentData(id: "removed-legacy", baseAgentId: "codex"))
        let profile = try profiles.add(template: removed, folder: root)
        let owner = store(InMemoryPersistence(initial: legacyState(agentID: removed.id, profile: profile, conversation: UUID().uuidString)))
        let tab = try XCTUnwrap(owner.active?.activeSession)
        XCTAssertEqual(tab.toolRoute, .allSessions)
        XCTAssertTrue(profiles.details.archive.origins.isEmpty)
    }

    func testTerminalPresetRestoresWorkingTerminal() throws {
        let previousSettings = AgentPadSettingsModel.testModel
        let settings = AgentPadSettingsModel(read: { [:] }, write: { _ in }, appliesRuntimeEffects: false)
        AgentPadSettingsModel.testModel = settings
        defer { AgentPadSettingsModel.testModel = previousSettings }
        let preset = TerminalPreset(id: "preset-work", title: "Work", path: root.path)
        settings.terminalPresets = [preset]
        let template = AgentTemplate.fromTerminalPreset(preset)
        let currentDirectory = root.appendingPathComponent("later-cd")
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        for hidden in [false, true] {
            let memory = InMemoryPersistence(), owner = store(memory)
            let session = owner.addTab(in: owner.active!, template: template)
            session.currentDirectory = currentDirectory
            session.customTitle = "Build shell"
            XCTAssertTrue(owner.flushPersistence())
            owner.terminate()
            // Hiding a preset only removes it from the launcher, not saved tabs.
            settings.hiddenPresets = hidden ? [preset.id] : []

            let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
            let terminal = try XCTUnwrap(restored.active?.activeSession)
            XCTAssertEqual(terminal.id, session.id)
            XCTAssertEqual(terminal.agent, template)
            XCTAssertEqual(terminal.customTitle, "Build shell")
            XCTAssertTrue(terminal.hasProcess)
            XCTAssertNil(terminal.toolRoute)
            XCTAssertNil(terminal.unavailableTab)
            XCTAssertNil(terminal.launchOrigin)
            let config = try XCTUnwrap((terminal.engine as? TestEngine)?.startedConfigs.last)
            XCTAssertEqual(config.workingDirectory, currentDirectory.path)
            XCTAssertNil(config.environment["AGENTPAD_AGENT"])
            restored.terminate()
        }
    }

    func testAgentExitWithoutEndedHookRestoresWorkingTerminal() throws {
        for wrapperExit in [false, true] {
            let memory = InMemoryPersistence(), owner = store(memory)
            let session = owner.addTab(in: owner.active!, template: .codex, initialCwd: root)
            owner.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
            let engine = try XCTUnwrap(session.engine as? TestEngine)
            if wrapperExit {
                let launch = try XCTUnwrap(session.pendingAgentLaunch)
                engine.emitTitle("\(AgentLaunchExitMarker.prefix)\(launch.id):0")
            } else {
                session.pendingAgentLaunch = nil
                engine.emitCommandFinished(exit: 0, duration: 1)
            }
            XCTAssertTrue(session.agent.isShell)
            XCTAssertNil(session.launchOrigin)
            XCTAssertTrue(owner.flushPersistence()); owner.terminate()
            let restored = store(InMemoryPersistence(initial: try XCTUnwrap(memory.saved)))
            let terminal = try XCTUnwrap(restored.active?.activeSession)
            XCTAssertTrue(terminal.hasProcess)
            XCTAssertTrue(terminal.agent.isShell)
            XCTAssertNil(terminal.toolRoute)
            XCTAssertNil(terminal.launchOrigin)
            let config = try XCTUnwrap((terminal.engine as? TestEngine)?.startedConfigs.last)
            XCTAssertNil(config.environment["AGENTPAD_AGENT"])
        }
    }

}
