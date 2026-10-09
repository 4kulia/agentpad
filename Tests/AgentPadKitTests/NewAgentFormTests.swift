import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class NewAgentFormTests: XCTestCase {
    private var root: URL!
    private var stores: [WorkspaceStore] = []
    private var router: TabRouter!
    private var tabs: LocalFormTabs!
    private var profiles: AgentProfileStore!
    private var drafts: DraftRepository!
    private var starts = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("new-agent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profiles = AgentProfileStore(fileURL: root.appendingPathComponent("data/profiles.json"))
        drafts = DraftRepository(fileURL: root.appendingPathComponent("data/drafts.json"))
        router = TabRouter(); router.stores = { [weak self] in self?.stores ?? [] }
        tabs = LocalFormTabs(router: router)
        tabs.agentTemplates = { [.claudeCode, .codex] }
        tabs.agentOptions = { _ in "--model example" }
    }
    override func tearDown() async throws {
        stores.forEach { $0.terminate() }; stores = []
        try FileManager.default.removeItem(at: root)
    }
    private func store() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, agentProfiles: profiles,
            drafts: drafts, engineFactory: { [weak self] in self?.starts += 1; return TestEngine() },
            peerStores: { [weak self] in self?.stores ?? [] })
        stores.append(store); return store
    }

    func testBothEntriesReuseDraftAcrossWindowsAndAddClosesWithoutLaunching() throws {
        let a = store(), b = store()
        let session = try XCTUnwrap(tabs.newAgent(from: a)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.newAgent.folder = root.path
        form.newAgent.name = "My agent"
        XCTAssertTrue(tabs.newAgent(from: b) === session)
        XCTAssertEqual(tabs.form(state).newAgent.name, "My agent")
        XCTAssertTrue(b.handleTabDrop(droppedId: session.id, in: try XCTUnwrap(b.active)))
        tabs.addAgent(state)
        let profile = try XCTUnwrap(profiles.profiles.first)
        XCTAssertEqual(profile.name, "My agent")
        XCTAssertEqual(profile.launchOptions, "--model example")
        XCTAssertEqual(b.revealedAgentProfileID, profile.id)
        XCTAssertEqual(b.sidebarContent, .workspaces)
        XCTAssertEqual(b.workspaces.count, 1, "The list must stay visible after the last form tab closes")
        XCTAssertNil(router.owner(of: session.id)); XCTAssertTrue(state.isClosed)
        XCTAssertTrue(drafts.drafts.isEmpty)
        XCTAssertEqual(starts, 0, "Adding a profile must never create an engine")
        tabs.addAgent(state)
        XCTAssertEqual(profiles.profiles.count, 1)
    }

    func testDuplicateBaseTemplateAndSymlinkRevealExistingWithoutChangingItsNameOrOptions() throws {
        let existing = try profiles.add(template: .claudeCode, folder: root, name: "Original", launchOptions: "--model original")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "opus", baseAgentId: "claude-code"))
        tabs.agentTemplates = { [custom] }
        let owner = store(), state = try XCTUnwrap(tabs.newAgent(from: owner)?.tabState)
        let form = tabs.form(state)
        form.newAgent.folder = alias.path; form.newAgent.name = "Duplicate"
        XCTAssertEqual(tabs.duplicateAgent(state), existing)
        tabs.addAgent(state)
        XCTAssertEqual(profiles.profiles, [existing])
        XCTAssertEqual(owner.revealedAgentProfileID, existing.id)
        XCTAssertTrue(state.isClosed); XCTAssertEqual(starts, 0)
    }

    func testDraftRestoresAndMissingFolderKeepsInputUntilSuccessfulAdd() throws {
        let owner = store(), session = try XCTUnwrap(tabs.newAgent(from: owner)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.newAgent = NewAgentDraft(templateID: "codex", folder: root.appendingPathComponent("gone").path, name: "")
        tabs.addAgent(state)
        XCTAssertNotNil(form.error); XCTAssertFalse(state.isClosed); XCTAssertTrue(profiles.profiles.isEmpty)
        try owner.tabCloseCoordinator.save(state)
        owner.closeTab(session, in: try XCTUnwrap(owner.active))
        let reopened = try XCTUnwrap(tabs.newAgent(from: owner)?.tabState)
        XCTAssertEqual(reopened.route, state.route)
        XCTAssertEqual(tabs.form(reopened).newAgent, form.newAgent)
        tabs.form(reopened).newAgent.folder = root.path
        tabs.addAgent(reopened)
        XCTAssertEqual(profiles.profiles.first?.name, root.lastPathComponent)
        XCTAssertEqual(starts, 0)
    }

    func testFailedSaveLeavesFormOpenAndDiscardRestoresLastSavedDraft() throws {
        let owner = store(), session = try XCTUnwrap(tabs.newAgent(from: owner)), state = try XCTUnwrap(session.tabState)
        let form = tabs.form(state)
        form.newAgent.folder = root.path; form.newAgent.name = "Saved"
        try owner.tabCloseCoordinator.save(state)
        form.newAgent.name = "Unsaved"
        owner.tabCloseCoordinator.discardEdits(state)
        XCTAssertEqual(form.newAgent.name, "Saved")
        let dataFolder = root.appendingPathComponent("data")
        try FileManager.default.removeItem(at: dataFolder)
        try Data("blocks directory creation".utf8).write(to: dataFolder)
        tabs.addAgent(state)
        XCTAssertNotNil(form.error); XCTAssertFalse(state.isClosed)
        XCTAssertTrue(profiles.profiles.isEmpty); XCTAssertEqual(starts, 0)
    }

    func testNativeFormRendersInBothAppearances() throws {
        let owner = store(), state = try XCTUnwrap(tabs.newAgent(from: owner)?.tabState), form = tabs.form(state)
        form.newAgent.folder = root.path
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        for dark in [false, true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] },
                write: { _ in }, appliesRuntimeEffects: false)
            let host = NSHostingView(rootView: NewAgentFormView(state: state, tabs: tabs, form: form)
                .foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
                .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 650)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let path = ProcessInfo.processInfo.environment["AGENTPAD_TEST_ARTIFACTS"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("new-agent-native-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testSuccessfulAddCanRetryFailedDraftCleanupWithoutCreatingAnotherProfile() throws {
        var fail = false
        drafts = DraftRepository(fileURL: root.appendingPathComponent("drafts.json")) { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url)
        }
        let owner = store(), state = try XCTUnwrap(tabs.newAgent(from: owner)?.tabState)
        let form = tabs.form(state)
        form.newAgent.folder = root.path
        try owner.tabCloseCoordinator.save(state)
        fail = true
        tabs.addAgent(state)
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertNotNil(state.saveError); XCTAssertFalse(state.isClosed)
        XCTAssertFalse(form.completed, "The existing-agent action must remain usable for retry")
        fail = false
        tabs.addAgent(state)
        XCTAssertTrue(state.isClosed); XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertEqual(starts, 0)
    }
}
