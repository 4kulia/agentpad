import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentProfileSessionTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var stores: [WorkspaceStore] = []
    private var engines: [TestEngine] = []
    private let conversation = "11111111-2222-3333-4444-555555555555"

    override func setUp() async throws {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentpad-profile-sessions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
    }
    override func tearDown() async throws {
        try profiles.flush()
        stores.forEach { $0.terminate() }; stores = []
        try FileManager.default.removeItem(at: root)
    }
    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return canonicalDiskPath(url)
    }
    private func store(persistence: InMemoryPersistence = InMemoryPersistence(), globalOptions: String = "--model global") -> WorkspaceStore {
        let store = WorkspaceStore(persistence: persistence, initiallyEmpty: true, agentProfiles: profiles,
            engineFactory: { [weak self] in let engine = TestEngine(); self?.engines.append(engine); return engine },
            optionsProvider: { _ in globalOptions }, resumeProvider: { false }, conversationVisibility: { .init(channelIds: []) }, peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store); return store
    }
    private func record(_ cwd: URL, id: String? = nil, date: Double = 1) -> AgentSessionRecord {
        AgentSessionRecord(agentId: "codex", conversationId: id ?? conversation, title: "Earlier work", cwd: cwd,
            lastActivity: Date(timeIntervalSince1970: date), scannedAt: Date(timeIntervalSince1970: date))
    }
    private func config(_ session: Session) throws -> TerminalSessionConfig {
        try XCTUnwrap((session.engine as? TestEngine)?.startedConfigs.last)
    }

    /// These history/navigation fixtures explicitly bind known provenance.
    /// Unlinked hook and monitor reports themselves cannot establish ownership.
    @discardableResult
    private func bindHistory(_ session: Session, in owner: WorkspaceStore, id: String? = nil) throws -> AgentProfile {
        let cwd = URL(fileURLWithPath: try XCTUnwrap(config(session).workingDirectory))
        let conversationID = id ?? conversation
        let profile = try session.profileID.flatMap(profiles.profile)
            ?? profiles.add(template: session.agent, folder: cwd, launchOptions: session.launchOrigin?.options ?? "")
        try profiles.bind(record(cwd, id: conversationID), to: profile.id, origin: session.launchOrigin)
        owner.applyConversationId(conversationId: conversationID, sessionId: session.id)
        return profile
    }

    func testEachProfileClickStartsFreshInCurrentWorkspaceAndOwnOptionsNeverLeak() throws {
        let path = try folder("project"), owner = store()
        let profile = try profiles.add(template: .codex, folder: path, launchOptions: "--model own")
        let workspace = try XCTUnwrap(owner.active)
        workspace.sshRemoteHost = "remote-host"
        let a = try owner.startAgentProfile(profile.id).get(), b = try owner.startAgentProfile(profile.id).get()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNil(a.resumedConversationId); XCTAssertNil(b.resumedConversationId)
        XCTAssertEqual(owner.active?.id, workspace.id); XCTAssertEqual(owner.workspaces.count, 1)
        XCTAssertNil(a.sshWorkspaceHost)
        XCTAssertEqual(a.profileID, profile.id)
        XCTAssertEqual(try config(a).workingDirectory, path.path)
        XCTAssertTrue(try XCTUnwrap(config(a).environment["AGENTPAD_AGENT"]).contains("--model own"))
        XCTAssertFalse(try XCTUnwrap(config(a).environment["AGENTPAD_AGENT"]).contains("--model global"))
        let quick = owner.addTab(in: workspace, template: .codex, connection: .local)
        XCTAssertTrue(try XCTUnwrap(config(quick).environment["AGENTPAD_AGENT"]).contains("--model global"))
        XCTAssertNil(quick.profileID)
        let rows = owner.profileSessionItems(profile)
        XCTAssertEqual(Set(rows.map(\.id)), [a.id.uuidString, b.id.uuidString])
    }

    func testProfileConversationReportDoesNotInventTitleOrActivity() throws {
        let path = try folder("project"), owner = store()
        let profile = try profiles.add(template: .codex, folder: path, name: "My agent")
        let session = try owner.startAgentProfile(profile.id).get()
        XCTAssertNil(session.customTitle, "The agent name must not mask terminal session titles")
        owner.applyConversationId(conversationId: conversation, sessionId: session.id)
        let binding = try XCTUnwrap(profiles.binding(agentID: "codex", conversationID: conversation))
        XCTAssertEqual(binding.record.title, "")
        XCTAssertEqual(binding.record.lastActivity, .distantPast)
        session.terminalTitle = "Prepare the release"
        XCTAssertEqual(owner.profileSessionItems(profile).first?.title, "Prepare the release")
    }

    func testExplicitHistoryBindingKeepsLaunchFolderAfterProfileMoveAndShellCd() throws {
        let old = try folder("old"), new = try folder("new"), owner = store()
        let profile = try profiles.add(template: .codex, folder: old)
        let session = try owner.startAgentProfile(profile.id).get()
        try profiles.move(profile.id, to: new)
        session.engine.onPwdChange?(new.path)
        try bindHistory(session, in: owner, id: conversation)
        let binding = try XCTUnwrap(profiles.binding(agentID: "codex", conversationID: conversation))
        XCTAssertEqual(binding.profileID, profile.id); XCTAssertEqual(binding.record.cwd.path, old.path)
        try profiles.discoverKnown([record(new)])
        let rows = owner.profileSessionItems(try XCTUnwrap(profiles.profile(profile.id)))
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.id, session.id.uuidString)
        XCTAssertEqual(rows.first?.cwd.path, old.path)
        let next = try owner.startAgentProfile(profile.id).get()
        XCTAssertEqual(try config(next).workingDirectory, new.path)
        let secondConversation = UUID().uuidString
        try bindHistory(session, in: owner, id: secondConversation)
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: conversation)?.record.cwd.path, old.path)
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: secondConversation)?.record.cwd.path, old.path)
    }

    func testSessionClickFocusesSameLiveTabAcrossWindowsWithoutStartingAnother() throws {
        let path = try folder("project"), a = store(), b = store()
        let profile = try profiles.add(template: .codex, folder: path)
        let session = try a.startAgentProfile(profile.id).get()
        try bindHistory(session, in: a, id: conversation)
        try profiles.discoverKnown([record(path)])
        let row = try XCTUnwrap(b.profileSessionItems(profile).first)
        let count = engines.count
        XCTAssertTrue(try b.openProfileSession(row, profileID: profile.id).get() === session)
        XCTAssertEqual(a.active?.activeSession?.id, session.id); XCTAssertEqual(engines.count, count)
        XCTAssertTrue(try b.resumeAgentSession(record(path)).get() === session)
        XCTAssertEqual(engines.count, count)
    }

    func testHistoryResumeUsesOriginalFolderAndProfileOptionsAfterMove() throws {
        let old = try folder("old"), new = try folder("new"), owner = store(globalOptions: "--no-session-persistence")
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "codex-custom", baseAgentId: "codex"))
        owner.profileTemplates = { [custom] }
        let profile = try profiles.add(template: custom, folder: old, launchOptions: "--model own")
        try profiles.bind(record(old), to: profile.id, origin: AgentLaunchOrigin(template: custom, folder: old, options: profile.launchOptions))
        try profiles.move(profile.id, to: new)
        // A stale caller supplies the new folder; the binding is authoritative.
        let session = try owner.resumeAgentSession(record(new)).get()
        XCTAssertEqual(try config(session).workingDirectory, old.path)
        XCTAssertEqual(session.resumedConversationId, conversation)
        XCTAssertEqual(session.agent.id, custom.id); XCTAssertEqual(session.profileID, profile.id)
        XCTAssertTrue(try XCTUnwrap(config(session).environment["AGENTPAD_AGENT"]).contains("--model own"))
    }

    func testMissingOriginalFolderDisablesHistoryAndRefusesResumeWithoutAnyEngine() throws {
        let old = try folder("old"), new = try folder("new"), owner = store()
        let profile = try profiles.add(template: .codex, folder: old)
        try profiles.discoverKnown([record(old)])
        try profiles.move(profile.id, to: new)
        try FileManager.default.removeItem(at: old)
        let row = try XCTUnwrap(owner.profileSessionItems(profile).first)
        XCTAssertFalse(row.canOpen); XCTAssertTrue(row.unavailableReason.contains(old.path))
        XCTAssertThrowsError(try owner.openProfileSession(row, profileID: profile.id).get())
        XCTAssertThrowsError(try owner.resumeAgentSession(record(new)).get())
        XCTAssertTrue(engines.isEmpty)
        XCTAssertTrue(try owner.startAgentProfile(profile.id).get().profileOriginalCwd?.path == new.path)
    }

    func testMissingProfileFolderRefusesNewLaunchButExistingSessionCanStillResume() throws {
        let old = try folder("old"), new = try folder("new"), owner = store()
        let profile = try profiles.add(template: .codex, folder: old)
        try profiles.discoverKnown([record(old)])
        try profiles.move(profile.id, to: new)
        try FileManager.default.removeItem(at: new)
        XCTAssertThrowsError(try owner.startAgentProfile(profile.id).get())
        XCTAssertTrue(engines.isEmpty); XCTAssertNotNil(owner.agentProfileErrors[profile.id])
        let session = try owner.resumeAgentSession(record(old)).get()
        XCTAssertEqual(try config(session).workingDirectory, old.path)
    }

    func testRecentFirstPaginationAndSameConversationDoNotDuplicateLiveRows() throws {
        let path = try folder("project"), owner = store(), profile = try profiles.add(template: .codex, folder: path)
        try profiles.discoverKnown((1...12).map { record(path, id: "id-\($0)", date: Double($0)) })
        var rows = owner.profileSessionItems(profile)
        XCTAssertEqual(rows.first?.record?.conversationId, "id-12")
        XCTAssertEqual(AgentProfileSessions.page(rows, limit: 5).count, 5)
        XCTAssertEqual(AgentProfileSessions.page(rows, limit: 10).count, 10)
        XCTAssertEqual(AgentProfileSessions.page(rows, limit: 15).count, 12)
        let session = try owner.startAgentProfile(profile.id).get()
        try bindHistory(session, in: owner, id: "id-12")
        rows = owner.profileSessionItems(profile)
        XCTAssertEqual(rows.count, 12); XCTAssertEqual(rows.first?.id, session.id.uuidString)
    }

    func testCustomCommandIconDoesNotInheritResumeAndMissingTemplateDoesNotStartShell() throws {
        let path = try folder("project"), owner = store()
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "aider", command: "aider --model sonnet", iconAsset: "claude"))
        owner.profileTemplates = { [custom] }
        let profile = try profiles.add(template: custom, folder: path)
        let session = try owner.startAgentProfile(profile.id).get()
        XCTAssertNil(session.agent.resumeStrategy); XCTAssertNil(session.agent.baseAgentId)
        XCTAssertFalse(try XCTUnwrap(config(session).environment["AGENTPAD_AGENT"]).contains("--resume"))
        XCTAssertEqual(owner.profileSessionItems(profile).first?.id, session.id.uuidString)
        owner.profileTemplates = { [] }
        let count = engines.count
        XCTAssertThrowsError(try owner.startAgentProfile(profile.id).get())
        XCTAssertEqual(engines.count, count)
    }

    func testRestartRestoresProfileBindingOptionsAndOriginalCwdWithoutWorkspaceFallback() throws {
        let old = try folder("old"), new = try folder("new"), persistence = InMemoryPersistence()
        let owner = store(persistence: persistence), profile = try profiles.add(template: .codex, folder: old, launchOptions: "--model own")
        let session = try owner.startAgentProfile(profile.id).get()
        try bindHistory(session, in: owner, id: conversation)
        session.engine.onPwdChange?(new.path)
        try profiles.move(profile.id, to: new)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let restored = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(persistence.saved)))
        let tab = try XCTUnwrap(restored.active?.activeSession)
        XCTAssertEqual(tab.id, session.id); XCTAssertEqual(tab.profileID, profile.id)
        XCTAssertEqual(tab.profileOriginalCwd?.path, old.path)
        XCTAssertEqual(try config(tab).workingDirectory, old.path)
        XCTAssertTrue(try XCTUnwrap(config(tab).environment["AGENTPAD_AGENT"]).contains("--model own"))
        restored.terminate()
        try FileManager.default.removeItem(at: old)
        let count = engines.count, missing = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(persistence.saved)))
        XCTAssertEqual(engines.count, count)
        XCTAssertFalse(try XCTUnwrap(missing.active?.activeSession).hasProcess)
        XCTAssertNotNil(missing.agentProfileErrors[profile.id])
    }

    func testReopenClosedProfileRefusesMissingOriginalFolder() throws {
        let path = try folder("project"), owner = store(), profile = try profiles.add(template: .codex, folder: path)
        let session = try owner.startAgentProfile(profile.id).get()
        let workspace = try XCTUnwrap(owner.active)
        _ = owner.addTab(in: workspace)
        owner.closeTab(session, in: workspace)
        try FileManager.default.removeItem(at: path)
        let count = engines.count
        XCTAssertNil(owner.reopenLastClosedTab())
        XCTAssertEqual(engines.count, count); XCTAssertNotNil(owner.agentProfileErrors[profile.id])
    }

    func testGenericHistoryResumeAlsoRefusesMissingCwd() {
        let owner = store(), missing = root.appendingPathComponent("missing")
        XCTAssertThrowsError(try owner.resumeAgentSession(record(missing)).get())
        XCTAssertTrue(engines.isEmpty)
    }

    func testRestoreHistoryBoundQuickTabUsesOriginalFolderWithoutProfileID() throws {
        let original = try folder("original"), other = try folder("other"), persistence = InMemoryPersistence()
        let owner = store(persistence: persistence), workspace = try XCTUnwrap(owner.active)
        let tab = owner.addTab(in: workspace, template: .codex, initialCwd: original)
        let profile = try bindHistory(tab, in: owner, id: conversation)
        try profiles.discoverKnown([record(original)])
        XCTAssertNil(tab.profileID)
        tab.engine.onPwdChange?(other.path)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let saved = try XCTUnwrap(persistence.saved)
        let restored = store(persistence: InMemoryPersistence(initial: saved))
        XCTAssertEqual(try config(XCTUnwrap(restored.active?.activeSession)).workingDirectory, original.path)
        restored.terminate()
        try FileManager.default.removeItem(at: original)
        let count = engines.count, missing = store(persistence: InMemoryPersistence(initial: saved))
        XCTAssertEqual(engines.count, count)
        XCTAssertFalse(try XCTUnwrap(missing.active?.activeSession).hasProcess)
        XCTAssertTrue(missing.agentProfileErrors[profile.id]?.contains(original.path) == true)
    }

    func testReopenHistoryBoundQuickTabRefusesMissingOriginalFolderWithoutProfileID() throws {
        let original = try folder("original"), other = try folder("other"), owner = store()
        let workspace = try XCTUnwrap(owner.active)
        let tab = owner.addTab(in: workspace, template: .codex, initialCwd: original)
        let profile = try bindHistory(tab, in: owner, id: conversation)
        try profiles.discoverKnown([record(original)])
        tab.engine.onPwdChange?(other.path)
        _ = owner.addTab(in: workspace)
        owner.closeTab(tab, in: workspace)
        try FileManager.default.removeItem(at: original)
        let count = engines.count
        XCTAssertNil(owner.reopenLastClosedTab())
        XCTAssertEqual(engines.count, count)
        XCTAssertTrue(owner.agentProfileErrors[profile.id]?.contains(original.path) == true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let reopened = try XCTUnwrap(owner.reopenLastClosedTab())
        XCTAssertEqual(try config(reopened).workingDirectory, original.path)
        XCTAssertEqual(reopened.profileID, profile.id)
    }

    func testUnavailableProfileTabRetainsDescriptionAcrossRestartAndRecovers() throws {
        let path = try folder("project"), persistence = InMemoryPersistence(), owner = store(persistence: persistence)
        let profile = try profiles.add(template: .codex, folder: path, name: "Project", launchOptions: "--model own")
        let session = try owner.startAgentProfile(profile.id).get()
        try bindHistory(session, in: owner, id: conversation)
        let original = PersistedTab(session)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        try FileManager.default.removeItem(at: path)
        let unavailablePersistence = InMemoryPersistence(initial: try XCTUnwrap(persistence.saved))
        let unavailable = store(persistence: unavailablePersistence)
        let placeholder = try XCTUnwrap(unavailable.active?.activeSession)
        XCTAssertFalse(placeholder.hasProcess)
        XCTAssertEqual(PersistedTab(placeholder), original)
        XCTAssertTrue(unavailable.flushPersistence()); unavailable.terminate()
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let recovered = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(unavailablePersistence.saved)))
        let tab = try XCTUnwrap(recovered.active?.activeSession)
        XCTAssertTrue(tab.hasProcess)
        XCTAssertEqual(PersistedTab(tab), original)
        XCTAssertEqual(try config(tab).workingDirectory, path.path)
    }

    func testUnavailableProfileArchiveDoesNotEraseRestorableTab() throws {
        let path = try folder("project"), file = root.appendingPathComponent("profiles.json")
        let persistence = InMemoryPersistence(), owner = store(persistence: persistence)
        let profile = try profiles.add(template: .codex, folder: path)
        let session = try owner.startAgentProfile(profile.id).get(), original = PersistedTab(session)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let archive = try Data(contentsOf: file)
        try Data("broken".utf8).write(to: file)
        profiles = AgentProfileStore(fileURL: file)
        let unavailablePersistence = InMemoryPersistence(initial: try XCTUnwrap(persistence.saved))
        let unavailable = store(persistence: unavailablePersistence)
        XCTAssertFalse(try XCTUnwrap(unavailable.active?.activeSession).hasProcess)
        XCTAssertTrue(unavailable.flushPersistence()); unavailable.terminate()
        try archive.write(to: file)
        profiles = AgentProfileStore(fileURL: file)
        let recovered = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(unavailablePersistence.saved)))
        XCTAssertEqual(PersistedTab(try XCTUnwrap(recovered.active?.activeSession)), original)
        XCTAssertTrue(try XCTUnwrap(recovered.active?.activeSession).hasProcess)
    }

    func testReopeningUnavailableTabKeepsRecoverableDescription() throws {
        let path = try folder("project"), persistence = InMemoryPersistence(), owner = store(persistence: persistence)
        let profile = try profiles.add(template: .codex, folder: path)
        let session = try owner.startAgentProfile(profile.id).get()
        try bindHistory(session, in: owner, id: conversation)
        var original = PersistedTab(session)
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        try FileManager.default.removeItem(at: path)
        let unavailable = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(persistence.saved)))
        let workspace = try XCTUnwrap(unavailable.active), tab = try XCTUnwrap(workspace.activeSession)
        _ = unavailable.addTab(in: workspace)
        unavailable.closeTab(tab, in: workspace)
        let reopened = try XCTUnwrap(unavailable.reopenLastClosedTab())
        original.id = reopened.id
        XCTAssertEqual(PersistedTab(reopened), original)
        XCTAssertTrue(reopened.tabState?.message?.contains(path.path) == true)
    }

    func testDuplicateProfileKeepsOwnOptionsAndLocalConnectionInSSHWorkspace() throws {
        let path = try folder("project"), owner = store(), workspace = try XCTUnwrap(owner.active)
        workspace.sshRemoteHost = "remote-host"
        let profile = try profiles.add(template: .codex, folder: path, launchOptions: "--model own")
        let source = try owner.startAgentProfile(profile.id).get()
        try bindHistory(source, in: owner, id: conversation)
        let duplicate = try XCTUnwrap(owner.duplicateTab(source, in: workspace))
        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(duplicate.profileID, profile.id)
        XCTAssertNil(duplicate.sshWorkspaceHost)
        XCTAssertNil(duplicate.conversationId)
        XCTAssertEqual(try config(duplicate).workingDirectory, path.path)
        let command = try XCTUnwrap(config(duplicate).environment["AGENTPAD_AGENT"])
        XCTAssertTrue(command.contains("--model own"), command)
        XCTAssertFalse(command.contains("--model global"), command)
    }

    func testDifferentToolHookClearsProfileAndRestoreKeepsActualTool() async throws {
        let path = try folder("project"), persistence = InMemoryPersistence(), owner = store(persistence: persistence)
        let profile = try profiles.add(template: .codex, folder: path, launchOptions: "--model codex-only")
        let session = try owner.startAgentProfile(profile.id).get()
        owner.applyHookEvent(agent: .codex, event: .running, sessionId: session.id)
        XCTAssertEqual(session.profileID, profile.id)
        owner.applyHookEvent(agent: .codex, event: .ended, sessionId: session.id)
        owner.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        owner.applyHookConversationId(conversationId: conversation, sessionId: session.id)
        XCTAssertEqual(session.agent.id, AgentTemplate.claudeCodeID)
        XCTAssertNil(session.profileID)
        XCTAssertNil(session.profileOriginalCwd)
        // Also repair stale metadata saved by the earlier version.
        session.profileID = profile.id; session.profileOriginalCwd = path
        XCTAssertTrue(owner.flushPersistence()); owner.terminate()
        let restored = store(persistence: InMemoryPersistence(initial: try XCTUnwrap(persistence.saved)))
        let tab = try XCTUnwrap(restored.active?.activeSession)
        XCTAssertEqual(tab.agent.id, AgentTemplate.claudeCodeID)
        await profiles.waitForTabAdoption()
        let adopted = try XCTUnwrap(profiles.profiles.first { $0.rosterID == AgentTemplate.claudeCodeID })
        XCTAssertEqual(tab.profileID, adopted.id)
        XCTAssertNotEqual(adopted.id, profile.id)
        XCTAssertEqual(adopted.rosterID, AgentTemplate.claudeCodeID)
        XCTAssertEqual(profiles.profile(profile.id), profile)
        XCTAssertFalse(try XCTUnwrap(config(tab).environment["AGENTPAD_AGENT"]).contains("--model codex-only"))
    }

    func testNormalDiscoveryAttachesHistoryAfterAdd() async throws {
        let path = try folder("project"), profile = try profiles.add(template: .codex, folder: path)
        let history = AgentSessionHistory(profiles: profiles), found = record(path)
        try profiles.rememberKnownOrigins([found])
        history.scan = { [found] in [found] }
        history.refresh()
        for _ in 0..<100 where history.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(history.isScanning)
        XCTAssertEqual(profiles.records(for: profile.id).map(\.conversationId), [conversation])
    }

    func testAllSessionsCatalogDiscoveryAlsoPersistsOwnership() async throws {
        let path = try folder("project"), profile = try profiles.add(template: .codex, folder: path), found = record(path)
        try profiles.rememberKnownOrigins([found])
        let catalog = SessionCatalog(profiles: profiles) { _ in
            .init(records: [found], scanned: 1, total: 1, skipped: 0)
        }
        catalog.refresh()
        for _ in 0..<100 where catalog.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(catalog.isScanning)
        XCTAssertEqual(profiles.binding(agentID: "codex", conversationID: conversation)?.profileID, profile.id)
    }

    func testProfileListRendersLiveHistoryPaginationAndMissingFolder() throws {
        let path = try folder("billing-api"), owner = store()
        let profile = try profiles.add(template: .codex, folder: path, name: "Billing")
        try profiles.discoverKnown((1...8).map {
            AgentSessionRecord(agentId: "codex", conversationId: "id-\($0)", title: "Session \($0)", cwd: path,
                lastActivity: Date(timeIntervalSince1970: Double($0)))
        })
        let missingFolder = try folder("missing"), missing = try profiles.add(template: .claudeCode, folder: missingFolder, name: "Moved project")
        try profiles.discoverKnown([AgentSessionRecord(agentId: "claude-code", conversationId: conversation,
            title: "Work in the original folder", cwd: missingFolder, lastActivity: Date())])
        try FileManager.default.removeItem(at: missingFolder)
        owner.expandedAgentProfiles = [profile.id, missing.id]
        owner.startAgentProfile(profile.id)
        owner.startAgentProfile(missing.id)
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for dark in [false, true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] },
                write: { _ in }, appliesRuntimeEffects: false)
            let history = AgentSessionHistory(profiles: profiles)
            history.scan = { [] }
            let host = NSHostingView(rootView: AgentProfilesSection(store: owner, history: history)
                .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
                .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 720)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("new-agent-list-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
