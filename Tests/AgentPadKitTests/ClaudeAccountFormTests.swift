import AppKit
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ClaudeAccountFormTests: XCTestCase {
    func testAddNormalizesNameClearsCredentialAndReturnsSavedMetadata() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let form = ClaudeAccountForm(profiles: profiles)
        let value = UUID().uuidString
        form.name = "  Work  "
        form.token = value
        let account = try XCTUnwrap(form.apply())
        XCTAssertEqual(account.name, "Work")
        XCTAssertEqual(profiles.claudeAccounts.list, [account])
        XCTAssertTrue(try profiles.claudeAccounts.token(id: account.id) == value)
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertNil(form.problem)
    }

    func testInvalidNameAndTokenKeepDraftWithoutCreatingAccount() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let form = ClaudeAccountForm(profiles: profiles)
        let value = UUID().uuidString
        form.name = " \n "
        form.token = value
        XCTAssertNil(form.apply())
        XCTAssertEqual(form.problem, "Enter a single-line account name.")
        XCTAssertTrue(form.token == value)
        XCTAssertEqual(profiles.claudeAccounts.list, [])
        XCTAssertEqual(try tokens.accounts(), [])
        form.name = "Work"
        form.token = ""
        XCTAssertNil(form.apply())
        XCTAssertEqual(form.problem, ClaudeAccountStore.Problem.invalidToken.localizedDescription)
        XCTAssertEqual(profiles.claudeAccounts.list, [])
        XCTAssertEqual(try tokens.accounts(), [])
    }

    func testCancelClearsCredentialAndUnsavedName() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let form = ClaudeAccountForm(profiles: profiles)
        form.name = "Work"
        form.token = UUID().uuidString
        form.cancel()
        XCTAssertEqual(form.name, "")
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertNil(form.problem)
        XCTAssertEqual(profiles.claudeAccounts.list, [])
        XCTAssertEqual(try tokens.accounts(), [])
    }

    func testReplaceKeepsMetadataAndProfileAssignment() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let account = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString)
        let profile = try profiles.add(template: .claudeCode, folder: FileManager.default.temporaryDirectory)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        let assigned = try XCTUnwrap(profiles.profile(profile.id))
        let form = ClaudeAccountForm(profiles: profiles, replacing: account.id)
        XCTAssertEqual(form.name, "Work")
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertTrue(form.isReplacing)
        let value = UUID().uuidString
        form.token = value
        let replaced = try XCTUnwrap(form.apply())
        XCTAssertEqual(replaced, ClaudeAccount(id: account.id, name: account.name, createdAt: account.createdAt,
            credentialRevision: replaced.credentialRevision))
        XCTAssertNotEqual(replaced.credentialRevision, account.credentialRevision)
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertEqual(profiles.claudeAccounts.list, [replaced])
        XCTAssertEqual(profiles.profile(profile.id), assigned)
        XCTAssertTrue(try profiles.claudeAccounts.token(id: account.id) == value)
    }

    func testFailedCredentialWriteKeepsDraftForRetryAndCancelClearsIt() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let account = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString)
        let form = ClaudeAccountForm(profiles: profiles, replacing: account.id)
        let value = UUID().uuidString
        form.token = value
        tokens.fails = true
        XCTAssertNil(form.apply())
        XCTAssertEqual(form.problem, ClaudeAccountStore.Problem.keychain.localizedDescription)
        XCTAssertTrue(form.token == value)
        XCTAssertEqual(profiles.claudeAccounts.list, [account])
        form.cancel()
        XCTAssertEqual(form.name, account.name)
        XCTAssertTrue(form.token.isEmpty)
        XCTAssertNil(form.problem)
        tokens.fails = false
        form.token = value
        let replaced = try XCTUnwrap(form.apply())
        XCTAssertEqual(replaced, ClaudeAccount(id: account.id, name: account.name, createdAt: account.createdAt,
            credentialRevision: replaced.credentialRevision))
        XCTAssertNotEqual(replaced.credentialRevision, account.credentialRevision)
        XCTAssertEqual(profiles.claudeAccounts.list, [replaced])
        XCTAssertTrue(form.token.isEmpty)
    }

    func testReplacementOfRemovedAccountCannotCreateAnotherAccount() throws {
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let account = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString)
        let form = ClaudeAccountForm(profiles: profiles, replacing: account.id)
        try profiles.claudeAccounts.remove(id: account.id)
        form.token = UUID().uuidString
        XCTAssertNil(form.apply())
        XCTAssertEqual(form.problem, ClaudeAccountStore.Problem.missingAccount.localizedDescription)
        XCTAssertEqual(profiles.claudeAccounts.list, [])
        XCTAssertEqual(try tokens.accounts(), [])
    }

    func testExpiryUsesCalendarYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let created = try XCTUnwrap(calendar.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 12)))
        let account = ClaudeAccount(id: UUID(), name: "Work", createdAt: created)
        let expiry = try XCTUnwrap(calendar.date(from: DateComponents(year: 2029, month: 2, day: 28, hour: 12)))
        XCTAssertEqual(ClaudeAccountsSettingsView.expires(account, calendar: calendar), expiry)
    }

    func testProfileAccountCommandsKeepCurrentSelectionAndNameDraft() throws {
        let teamScope = TeamServiceTestScope()
        defer { teamScope.close() }
        let tokens = MemoryClaudeTokens()
        let profiles = AgentProfileStore(accountTokens: tokens)
        let account = try profiles.claudeAccounts.add(name: "Work", token: UUID().uuidString)
        let profile = try profiles.add(template: .claudeCode, folder: FileManager.default.temporaryDirectory)
        let editor = AgentProfileEditor(profile: profile, profiles: profiles)
        editor.name = "Unfinished name"
        let state = TabState(route: .agentProfile(profile.id))
        state.isPopup = true
        let host = NSHostingView(rootView: AgentProfileEditorView(state: state, editor: editor))
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 600)
        host.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(accountPopup(host))
        XCTAssertEqual(menu.itemArray.map(\.title), ["Main account", "Work", "", "Add account…", "Manage accounts…"])
        for selection in [nil, account.id] {
            editor.claudeAccountID = selection
            host.layoutSubtreeIfNeeded()
            for command in ["Add account…", "Manage accounts…"] {
                menu.selectItem(withTitle: command)
                XCTAssertTrue(menu.sendAction(menu.action, to: menu.target))
                XCTAssertEqual(editor.claudeAccountID, selection)
                XCTAssertEqual(menu.selectedItem?.representedObject as? UUID, selection)
                XCTAssertEqual(editor.name, "Unfinished name")
                XCTAssertEqual(profiles.profile(profile.id), profile)
            }
        }
    }

    private func accountPopup(_ view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.identifier?.rawValue == "claude-account-popup" { return popup }
        return view.subviews.lazy.compactMap { self.accountPopup($0) }.first
    }
}
