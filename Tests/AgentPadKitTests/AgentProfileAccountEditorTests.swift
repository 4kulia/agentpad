import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentProfileAccountEditorTests: XCTestCase {
    private var root: URL!
    private var profiles: AgentProfileStore!
    private var account: ClaudeAccount!
    private var profile: AgentProfile!
    private var tokens: MemoryClaudeTokens!
    private var teamScope: TeamServiceTestScope!
    private var file: URL { root.appendingPathComponent("agent-profiles.json") }

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("account-editor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokens = MemoryClaudeTokens()
        profiles = AgentProfileStore(fileURL: file, accountTokens: tokens)
        account = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString)
        profile = try profiles.add(template: .claudeCode, folder: root, name: "Reviewer")
    }
    override func tearDown() async throws {
        teamScope.close(); teamScope = nil
        try FileManager.default.removeItem(at: root)
    }

    func testSelectionLoadsSavesAndReturnsToMainWithoutHint() throws {
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        XCTAssertTrue(editor.showsClaudeAccount)
        XCTAssertNil(editor.claudeAccountID); XCTAssertNil(editor.claudeAccountHint)
        editor.claudeAccountID = account.id; editor.name = "New name"
        XCTAssertEqual(editor.claudeAccountHint,
            "New sessions of this agent use the Work subscription. Running sessions keep their account until restarted.")
        editor.saveName()
        let reloaded = AgentProfileStore(fileURL: file, accountTokens: tokens)
        XCTAssertEqual(reloaded.profile(profile.id)?.claudeAccountID, account.id)
        XCTAssertEqual(reloaded.profile(profile.id)?.name, "New name")
        let next = AgentProfileEditor(profile: try XCTUnwrap(reloaded.profile(profile.id)), profiles: reloaded)
        XCTAssertEqual(next.claudeAccountID, account.id)
        next.claudeAccountID = nil; next.saveName()
        XCTAssertNil(next.claudeAccountHint)
        XCTAssertNil(AgentProfileStore(fileURL: file, accountTokens: tokens).profile(profile.id)?.claudeAccountID)
    }

    func testCancelDoesNotSaveAndConcurrentAccountEditRequiresReload() throws {
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        editor.claudeAccountID = account.id
        editor.invalidate(); editor.saveName()
        XCTAssertNil(profiles.profile(profile.id)?.claudeAccountID)
        let stale = AgentProfileEditor(profile: profile, profiles: profiles)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        stale.name = "Stale edit"; stale.saveName()
        XCTAssertEqual(stale.operation, .failed("This profile changed in another editor. Reload before saving.", recovery: .reload))
        XCTAssertEqual(profiles.profile(profile.id)?.name, profile.name)
        stale.reload()
        XCTAssertEqual(stale.claudeAccountID, account.id)
        stale.claudeAccountID = nil; stale.saveName()
        XCTAssertNil(profiles.profile(profile.id)?.claudeAccountID)
    }

    func testFailedSaveKeepsNameAndAccountTogetherAndRetryPersistsBoth() async throws {
        let writes = ProfileArchiveWriteProbe()
        profiles = AgentProfileStore(fileURL: file, accountTokens: tokens, write: { try writes.write($0, to: $1) })
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        editor.name = "Renamed"; editor.claudeAccountID = account.id
        let before = try Data(contentsOf: file)
        writes.fail = true; editor.saveName()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(profiles.profile(profile.id), profile)
        writes.fail = false; await editor.retry()
        let saved = try XCTUnwrap(AgentProfileStore(fileURL: file, accountTokens: tokens).profile(profile.id))
        XCTAssertEqual(saved.name, "Renamed"); XCTAssertEqual(saved.claudeAccountID, account.id)
    }

    func testNativePopupHasOnlyMainAndSavedAccountsAndSelectionSaves() throws {
        let second = try profiles.claudeAccounts.add(name: "Personal", token: UUID().uuidString)
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        let host = editorHost(editor)
        let popup = try XCTUnwrap(popups(host).first)
        XCTAssertEqual(popup.itemArray.map(\.title), ["Main account", "Work", "Personal"])
        XCTAssertEqual(popup.itemArray.map(\.subtitle), [nil, "Token in Keychain", "Token in Keychain"])
        popup.selectItem(at: 2)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(editor.claudeAccountID, second.id)
        editor.saveName()
        XCTAssertEqual(profiles.profile(profile.id)?.claudeAccountID, second.id)
    }

    func testPopupOnlyAppearsForBuiltInClaudeCode() throws {
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "custom-claude", baseAgentId: "claude-code"))
        for template in [AgentTemplate.claudeCode, .codex, custom] {
            let value = try profiles.add(template: template, folder: root)
            let editor = AgentProfileEditor(profile: value, profiles: profiles)
            XCTAssertEqual(editor.showsClaudeAccount, template.id == AgentTemplate.claudeCodeID)
            XCTAssertEqual(popups(editorHost(editor)).count, template.id == AgentTemplate.claudeCodeID ? 1 : 0)
        }
    }

    func testSidebarTagResolvesSavedAccountNameAndMainHasNone() throws {
        let owner = makeTestStore(agentProfiles: profiles)
        defer { owner.terminate() }
        let main = AgentProfileRow(store: owner, profile: profile, attentionCount: 0, select: { _ in })
        XCTAssertNil(main.accountName)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        let selected = AgentProfileRow(store: owner, profile: try XCTUnwrap(profiles.profile(profile.id)), attentionCount: 0, select: { _ in })
        XCTAssertEqual(selected.accountName, "Work")
    }

    func testEditorAndSidebarRenderMainAndWorkInBothAppearances() throws {
        let previous = AgentPadSettingsModel.testModel
        defer { AgentPadSettingsModel.testModel = previous }
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/acct1-ui")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let owner = makeTestStore(agentProfiles: profiles)
        defer { owner.terminate() }
        for dark in [false, true] {
            AgentPadSettingsModel.testModel = AgentPadSettingsModel(read: { ["appearance": ["mode": dark ? "dark" : "light"]] },
                write: { _ in }, appliesRuntimeEffects: false)
            for selected in [false, true] {
                try profiles.setClaudeAccount(profileID: profile.id, accountID: selected ? account.id : nil)
                let value = try XCTUnwrap(profiles.profile(profile.id))
                let editor = AgentProfileEditor(profile: value, profiles: profiles)
                let host = editorHost(editor)
                XCTAssertEqual(popups(host).count, 1)
                let suffix = "\(selected ? "work" : "main")-\(dark ? "dark" : "light")"
                try snapshot(host, to: artifacts.appendingPathComponent("editor-\(suffix).png"))
                let sidebar = NSHostingView(rootView: AgentProfileRow(store: owner, profile: value, attentionCount: 1, select: { _ in })
                    .padding(8).foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
                    .environment(\.colorScheme, Theme.chromeColorScheme))
                sidebar.frame = NSRect(x: 0, y: 0, width: 330, height: 80); sidebar.layoutSubtreeIfNeeded()
                try snapshot(sidebar, to: artifacts.appendingPathComponent("sidebar-\(suffix).png"))
            }
        }
    }

    private func editorHost(_ editor: AgentProfileEditor) -> NSHostingView<AgentProfileEditorView> {
        let host = NSHostingView(rootView: AgentProfileEditorView(state: TabState(route: .agentProfile(editor.id)), editor: editor))
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 700); host.layoutSubtreeIfNeeded()
        return host
    }
    private func popups(_ view: NSView) -> [NSPopUpButton] {
        if let popup = view as? NSPopUpButton, popup.identifier?.rawValue == "claude-account-popup" { return [popup] }
        return view.subviews.flatMap { popups($0) }
    }
    private func snapshot(_ view: NSView, to url: URL) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
